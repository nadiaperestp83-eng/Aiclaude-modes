#!/usr/bin/env bash
# Scored, read-only repo-health scorecard — orchestrates the github-ops auditors.
#
# READ-ONLY. Only GET `gh api` calls plus calls to the read-only sibling scripts
# (check-security-posture.sh, check-issues.sh). NEVER a -X PUT/PATCH/POST/DELETE.
# It rolls five dimensions into one 0–100 score + letter grade per repo, and
# (with --org) a fleet matrix + roll-up. The remediation pointers it prints are
# TEXT for you to act on — this script applies nothing.
#
# Usage:   repo-scorecard.sh [--repo OWNER/REPO | --remote NAME | --org OWNER]
#                            [--min-score N] [--json] [-h|--help]
# Input:   argv only. Default repo = derived from the 'origin' remote of the cwd.
# Output:  stdout = the data product (human matrix, or --json envelope).
#          --json schema: claude-mods.github-ops.repo-scorecard/v1
# Stderr:  headers, progress, the review banner, skip notices, errors.
# Exit:    0  all audited repos healthy (no gaps; or all >= --min-score)
#          2  usage (bad/unknown flag, malformed OWNER/REPO, mutex selectors)
#          5  gh not installed
#          7  unavailable — non-github remote, gh unauthed/offline, timeout
#             (graceful, like the siblings; never a false "healthy")
#          10 findings — gaps present, or a repo scored below --min-score
#
# SCORING MODEL (transparent rubric, documented so it is auditable):
#   Each dimension yields a status (ok / warn / gap / n/a) and earns a fraction
#   of its weight. n/a (couldn't read) earns ZERO and is never treated as ok.
#
#     Dimension   Weight   ok(full)        warn(half)              gap(zero)
#     ─────────   ──────   ────────        ──────────              ─────────
#     security      35     no gaps,        low/medium gaps only    high/critical gap
#                          0 open alerts                           OR any open alert
#     metadata      25     all 6 present   1–2 missing             3+ missing
#     release       15     >=1 release &   releases exist but      no releases at all
#                          latest tag      latest tag has no rel
#                          has a release
#     issues        15     none external   1–3 external/stale      4+ external/stale
#                          or stale
#     actions       10     latest run      no runs found (warn)    latest run = failure
#                          succeeded
#                                                    ─────
#                                          total weight = 100
#
#   score = round( sum(weight_i * fraction_i) ), fraction in {1, 0.5, 0}.
#   n/a dimensions earn 0 of their weight (honest: an unreadable security
#   dimension can NEVER score full). Grade: A>=90 B>=75 C>=60 D>=40 F<40.
#   Security is weighted highest by design; a single open critical alert or a
#   high-severity gap zeroes 35 points and caps the grade hard.
#
#   --min-score N: exit 10 if ANY audited repo scores below N (CI-gating knob),
#   independent of whether other gaps exist.
#
# Examples:
#   repo-scorecard.sh --repo 0xDarkMatter/flarecrawl
#   repo-scorecard.sh --org 0xDarkMatter
#   repo-scorecard.sh --repo OWNER/REPO --json | jq '.data[0].top_fixes'
#   repo-scorecard.sh --org OWNER --min-score 75   # CI gate: fail if any repo < 75
set -uo pipefail

EX_OK=0; EX_USAGE=2; EX_MISSING_DEP=5; EX_UNAVAILABLE=7; EX_FINDINGS=10
GH_TIMEOUT="${GH_TIMEOUT:-20}"   # seconds; bounds every network call

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEC="$HERE/check-security-posture.sh"
ISS="$HERE/check-issues.sh"

REPO=""; REMOTE="origin"; ORG=""; JSON=0; MIN_SCORE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="${2:?--repo needs OWNER/REPO}"; shift 2 ;;
    --remote)    REMOTE="${2:?--remote needs a name}"; shift 2 ;;
    --org)       ORG="${2:?--org needs an OWNER}"; shift 2 ;;
    --min-score) MIN_SCORE="${2:?--min-score needs N}"; shift 2 ;;
    --json)      JSON=1; shift ;;
    -h|--help)   sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//'; exit "$EX_OK" ;;
    *) echo "repo-scorecard: unknown argument: $1" >&2; exit "$EX_USAGE" ;;
  esac
done

skip() { echo "repo-scorecard: $1" >&2; exit "$EX_UNAVAILABLE"; }

command -v gh >/dev/null 2>&1 || {
  echo "repo-scorecard: gh not installed (https://cli.github.com)" >&2
  exit "$EX_MISSING_DEP"
}
command -v jq >/dev/null 2>&1 || skip "jq not installed"

# --min-score must be an integer if given.
if [ -n "$MIN_SCORE" ] && ! printf '%s' "$MIN_SCORE" | grep -Eq '^[0-9]+$'; then
  echo "repo-scorecard: --min-score needs an integer, got '$MIN_SCORE'" >&2; exit "$EX_USAGE"
fi

runner() { if command -v timeout >/dev/null 2>&1; then timeout "$GH_TIMEOUT" "$@"; else "$@"; fi; }

# Agent safety — never interpolate a fabricated path into a gh call.
valid_repo()  { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; }
valid_owner() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+$'; }

# Weights (sum = 100).
W_SECURITY=35; W_METADATA=25; W_RELEASE=15; W_ISSUES=15; W_ACTIONS=10

# --------------------------------------------------------------------------
# gh api wrapper that distinguishes "exists" from "404" from "couldn't read".
# Echoes body on success; sets a global GHRC: 0 ok, 4 not-found, 7 unavailable.
# --------------------------------------------------------------------------
gh_get() { # path  -> echoes body, sets GHRC
  local out
  out="$(runner gh api "$1" 2>/dev/null)"; local rc=$?
  if [ $rc -ne 0 ]; then
    # gh exits nonzero on 404 too; disambiguate via the error JSON if present.
    if printf '%s' "$out" | grep -q '"status": *"404"' 2>/dev/null; then GHRC=4; else GHRC=7; fi
    printf '%s' "$out"; return
  fi
  GHRC=0; printf '%s' "$out"
}

# Does a path exist in the repo? 0 yes, 1 no, 2 couldn't-read.
content_exists() { # OWNER/REPO  PATH
  if runner gh api "repos/$1/contents/$2" --silent >/dev/null 2>&1; then return 0; fi
  # --silent suppresses the body; re-probe to classify 404 vs auth/offline.
  local body; body="$(runner gh api "repos/$1/contents/$2" 2>&1)"
  printf '%s' "$body" | grep -q '404' && return 1
  return 2
}

# --------------------------------------------------------------------------
# Score ONE repo. Echoes a compact JSON object; returns 0 healthy / 10 findings
# / 7 unavailable (couldn't read the core repo object at all).
# --------------------------------------------------------------------------
score_repo() { # OWNER/REPO -> echoes JSON object; returns 0|10|7
  local R="$1" owner core vis
  owner="${R%%/*}"

  core="$(runner gh api "repos/$R" 2>/dev/null)" || return 7
  [ -n "$core" ] || return 7
  vis="$(printf '%s' "$core" | jq -r '.visibility // (if .private then "private" else "public" end)' | tr -d '\r')"
  local default_branch
  default_branch="$(printf '%s' "$core" | jq -r '.default_branch // "main"' | tr -d '\r')"

  # ---- DIMENSION: metadata (6 facets) -----------------------------------
  local md_desc md_home md_topics md_lic md_readme md_changelog md_missing=0 md_detail=""
  md_desc="$(printf '%s' "$core" | jq -r '.description // "" | length' | tr -d '\r')"
  md_home="$(printf '%s' "$core" | jq -r '.homepage // "" | length' | tr -d '\r')"
  # topics live on the core object as .topics (array).
  md_topics="$(printf '%s' "$core" | jq -r '(.topics // []) | length' | tr -d '\r')"

  [ "${md_desc:-0}" -gt 0 ] || { md_missing=$((md_missing+1)); md_detail="$md_detail description;"; }
  # homepage is optional — count it only as a soft facet (missing homepage does
  # NOT increment md_missing; it is informational). We track it for detail only.
  if [ "${md_home:-0}" -gt 0 ]; then md_home="set"; else md_home="unset"; fi
  if [ "${md_topics:-0}" -ge 3 ]; then :; else md_missing=$((md_missing+1)); md_detail="$md_detail topics<3;"; fi

  if content_exists "$R" "LICENSE"; then md_lic=1
  elif content_exists "$R" "LICENSE.md"; then md_lic=1
  else md_lic=0; md_missing=$((md_missing+1)); md_detail="$md_detail LICENSE;"; fi
  if content_exists "$R" "README.md"; then md_readme=1
  else md_readme=0; md_missing=$((md_missing+1)); md_detail="$md_detail README;"; fi
  if content_exists "$R" "CHANGELOG.md"; then md_changelog=1
  else md_changelog=0; md_missing=$((md_missing+1)); md_detail="$md_detail CHANGELOG;"; fi

  # 5 hard facets (description, topics>=3, LICENSE, README, CHANGELOG).
  local md_status md_frac
  if [ "$md_missing" -eq 0 ]; then md_status="ok"; md_frac="1"
  elif [ "$md_missing" -le 2 ]; then md_status="warn"; md_frac="0.5"
  else md_status="gap"; md_frac="0"; fi
  [ -n "$md_detail" ] || md_detail="all present"
  md_detail="${md_detail# }"

  # ---- DIMENSION: release ----------------------------------------------
  local rel_status rel_frac rel_detail rel_count latest_tag rel_for_tag
  rel_count="$(runner gh api "repos/$R/releases?per_page=1" --jq 'length' 2>/dev/null | tr -d '\r')"
  latest_tag="$(runner gh api "repos/$R/tags?per_page=1" --jq '.[0].name // ""' 2>/dev/null | tr -d '\r')"
  if [ -z "${rel_count:-}" ]; then
    rel_status="n/a"; rel_frac="0"; rel_detail="couldn't read releases"
  elif [ "$rel_count" -eq 0 ]; then
    rel_status="gap"; rel_frac="0"; rel_detail="no GitHub releases"
  else
    # >=1 release exists. Is the latest TAG backed by a release?
    if [ -n "$latest_tag" ]; then
      if runner gh api "repos/$R/releases/tags/$latest_tag" --silent >/dev/null 2>&1; then
        rel_status="ok"; rel_frac="1"; rel_detail="latest tag $latest_tag has a release"
      else
        rel_status="warn"; rel_frac="0.5"; rel_detail="latest tag $latest_tag has no release"
      fi
    else
      rel_status="ok"; rel_frac="1"; rel_detail="releases present (no tags listed)"
    fi
  fi

  # ---- DIMENSION: security (orchestrate the sibling) --------------------
  local sec_status sec_frac sec_detail sec_json sec_rc
  sec_json="$("$SEC" --repo "$R" --json 2>/dev/null)"; sec_rc=$?
  if [ "$sec_rc" -eq 7 ] || [ -z "$sec_json" ] || ! printf '%s' "$sec_json" | jq -e . >/dev/null 2>&1; then
    sec_status="n/a"; sec_frac="0"; sec_detail="security audit unavailable"
    local sec_gaps=-1 sec_alerts=-1 sec_maxsev="unknown"
  else
    # The single-repo envelope: {data:[features], meta:{gaps, open_alerts,...}}.
    local sec_gaps sec_alerts sec_maxsev
    sec_gaps="$(printf '%s' "$sec_json" | jq -r '.meta.gaps // 0')"
    sec_alerts="$(printf '%s' "$sec_json" | jq -r '.meta.open_alerts // 0')"
    # Max severity across (a) gap rows and (b) any open alert.
    sec_maxsev="$(printf '%s' "$sec_json" | jq -r '
      ([ .data[]
         | select(.applicable==true)
         | (if ((.open_alerts // 0) > 0) then .max_severity else empty end),
           (if (.state=="off" or .state=="unknown") then .severity else empty end) ]
       | map(select(. != null and . != "" and . != "none" and . != "note")
             | ascii_downcase)) as $s
      | (["critical","high","medium","low"] | map(select(. as $t | $s | index($t))) | .[0]) // "none"')"
    if [ "$sec_gaps" -eq 0 ] && [ "$sec_alerts" -eq 0 ]; then
      sec_status="ok"; sec_frac="1"; sec_detail="no gaps, 0 open alerts"
    elif [ "$sec_maxsev" = "critical" ] || [ "$sec_maxsev" = "high" ] || [ "$sec_alerts" -gt 0 ]; then
      sec_status="gap"; sec_frac="0"
      sec_detail="$sec_gaps gap(s), $sec_alerts open alert(s), max $sec_maxsev"
    else
      sec_status="warn"; sec_frac="0.5"
      sec_detail="$sec_gaps gap(s) (max $sec_maxsev), 0 open alerts"
    fi
  fi

  # ---- DIMENSION: issues (orchestrate the sibling) ----------------------
  local iss_status iss_frac iss_detail iss_json iss_rc iss_flagged=-1 iss_total=-1
  iss_json="$("$ISS" --repo "$R" --json 2>/dev/null)"; iss_rc=$?
  if [ "$iss_rc" -eq 7 ] || [ -z "$iss_json" ] || ! printf '%s' "$iss_json" | jq -e . >/dev/null 2>&1; then
    iss_status="n/a"; iss_frac="0"; iss_detail="issue audit unavailable"
  else
    iss_flagged="$(printf '%s' "$iss_json" | jq -r '.meta.flagged // 0')"
    iss_total="$(printf '%s' "$iss_json" | jq -r '.meta.total_open // 0')"
    if [ "$iss_flagged" -eq 0 ]; then
      iss_status="ok"; iss_frac="1"; iss_detail="$iss_total open, none external/stale"
    elif [ "$iss_flagged" -le 3 ]; then
      iss_status="warn"; iss_frac="0.5"; iss_detail="$iss_flagged external/stale of $iss_total open"
    else
      iss_status="gap"; iss_frac="0"; iss_detail="$iss_flagged external/stale of $iss_total open"
    fi
  fi

  # ---- DIMENSION: actions (single signal) -------------------------------
  local act_status act_frac act_detail act_json act_concl
  act_json="$(runner gh api "repos/$R/actions/runs?branch=$default_branch&per_page=1" 2>/dev/null)"
  if [ -z "$act_json" ] || ! printf '%s' "$act_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
    act_status="n/a"; act_frac="0"; act_detail="couldn't read workflow runs"
  else
    act_concl="$(printf '%s' "$act_json" | jq -r '.workflow_runs[0].conclusion // "none"' | tr -d '\r')"
    case "$act_concl" in
      success)            act_status="ok";   act_frac="1";   act_detail="latest run on $default_branch: success" ;;
      none|null|"")       act_status="warn"; act_frac="0.5"; act_detail="no workflow runs on $default_branch" ;;
      failure|timed_out|startup_failure)
                          act_status="gap";  act_frac="0";   act_detail="latest run on $default_branch: $act_concl" ;;
      *)                  act_status="warn"; act_frac="0.5"; act_detail="latest run on $default_branch: $act_concl" ;;
    esac
  fi

  # ---- Roll up the score -------------------------------------------------
  local score
  score="$(awk -v ws=$W_SECURITY -v wm=$W_METADATA -v wr=$W_RELEASE -v wi=$W_ISSUES -v wa=$W_ACTIONS \
    -v fs="$sec_frac" -v fm="$md_frac" -v fr="$rel_frac" -v fi="$iss_frac" -v fa="$act_frac" \
    'BEGIN{ printf "%d", int(ws*fs + wm*fm + wr*fr + wi*fi + wa*fa + 0.5) }')"
  local grade
  if   [ "$score" -ge 90 ]; then grade="A"
  elif [ "$score" -ge 75 ]; then grade="B"
  elif [ "$score" -ge 60 ]; then grade="C"
  elif [ "$score" -ge 40 ]; then grade="D"
  else grade="F"; fi

  # ---- Top 3 fixes (highest-severity gaps first) -------------------------
  # Build a ranked list. Each entry: severity-rank \t status \t text.
  # rank 0 highest. Only surface dimensions that are gap/warn/n/a.
  local fixes="[]"
  addfix() { # rank status text
    fixes="$(jq -c --argjson r "$1" --arg st "$2" --arg t "$3" \
      '. + [{rank:$r, status:$st, fix:$t}]' <<<"$fixes")"
  }
  # security first (highest weight). Map maxsev to a rank.
  if [ "$sec_status" = "gap" ]; then
    addfix 0 gap "security: $sec_detail → check-security-posture.sh --repo $R --commands"
  elif [ "$sec_status" = "warn" ]; then
    addfix 3 warn "security: $sec_detail → check-security-posture.sh --repo $R --commands"
  elif [ "$sec_status" = "n/a" ]; then
    addfix 5 "n/a" "security: couldn't read → re-run check-security-posture.sh --repo $R"
  fi
  if [ "$md_status" = "gap" ]; then
    addfix 1 gap "metadata: missing ${md_detail} → set description / >=3 topics / add the missing file(s)"
  elif [ "$md_status" = "warn" ]; then
    addfix 4 warn "metadata: missing ${md_detail} → set description / >=3 topics / add the missing file(s)"
  fi
  if [ "$rel_status" = "gap" ]; then
    addfix 2 gap "release: $rel_detail → cut a GitHub release (github-ops mode update)"
  elif [ "$rel_status" = "warn" ]; then
    addfix 4 warn "release: $rel_detail → gh release create $latest_tag"
  fi
  if [ "$iss_status" = "gap" ]; then
    addfix 2 gap "issues: $iss_detail → check-issues.sh --repo $R"
  elif [ "$iss_status" = "warn" ]; then
    addfix 5 warn "issues: $iss_detail → check-issues.sh --repo $R"
  fi
  if [ "$act_status" = "gap" ]; then
    addfix 1 gap "actions: $act_detail → inspect the failing run (gh run list --repo $R)"
  elif [ "$act_status" = "warn" ]; then
    addfix 5 warn "actions: $act_detail"
  fi
  local top_fixes
  top_fixes="$(printf '%s' "$fixes" | jq -c 'sort_by(.rank) | [ .[] | .fix ] | .[0:3]')"

  # ---- Assemble the per-repo object -------------------------------------
  jq -c -n \
    --arg repo "$R" --arg vis "$vis" --argjson score "$score" --arg grade "$grade" \
    --arg md_st "$md_status" --arg md_d "$md_detail" \
    --arg rel_st "$rel_status" --arg rel_d "$rel_detail" \
    --arg sec_st "$sec_status" --arg sec_d "$sec_detail" \
    --argjson sec_gaps "${sec_gaps:-0}" --argjson sec_alerts "${sec_alerts:-0}" --arg sec_mx "${sec_maxsev:-none}" \
    --arg iss_st "$iss_status" --arg iss_d "$iss_detail" --argjson iss_fl "${iss_flagged:-0}" \
    --arg act_st "$act_status" --arg act_d "$act_detail" \
    --argjson topf "$top_fixes" \
    '{repo:$repo, visibility:$vis, score:$score, grade:$grade,
      dimensions:{
        metadata:{status:$md_st, detail:$md_d},
        release:{status:$rel_st, detail:$rel_d},
        security:{status:$sec_st, detail:$sec_d, gaps:(if $sec_gaps<0 then null else $sec_gaps end), open_alerts:(if $sec_alerts<0 then null else $sec_alerts end), max_severity:$sec_mx},
        issues:{status:$iss_st, detail:$iss_d, flagged:(if $iss_fl<0 then null else $iss_fl end)},
        actions:{status:$act_st, detail:$act_d}
      },
      top_fixes:$topf}'

  # Per-repo exit: findings if any dimension is gap, n/a, or warn? We count
  # gap/n/a as findings (real problems). warn does not by itself trip exit 10
  # unless --min-score applies. (n/a is a finding — never a clean pass.)
  if [ "$md_status" = "gap" ] || [ "$rel_status" = "gap" ] || [ "$sec_status" = "gap" ] || \
     [ "$iss_status" = "gap" ] || [ "$act_status" = "gap" ] || \
     [ "$md_status" = "n/a" ] || [ "$rel_status" = "n/a" ] || [ "$sec_status" = "n/a" ] || \
     [ "$iss_status" = "n/a" ] || [ "$act_status" = "n/a" ]; then
    return 10
  fi
  return 0
}

# Glyph for a dimension status (human matrix).
mark() { case "$1" in
  ok) printf 'ok ';; warn) printf 'warn';; gap) printf 'GAP ';; "n/a") printf 'n/a ';; *) printf '?   ';; esac; }

# Human single-repo card (data to stdout; framing to stderr).
print_card() { # repo_json
  local o="$1" repo vis score grade
  repo="$(jq -r '.repo' <<<"$o")"; vis="$(jq -r '.visibility' <<<"$o")"
  score="$(jq -r '.score' <<<"$o")"; grade="$(jq -r '.grade' <<<"$o")"
  {
    echo "REPO SCORECARD — $repo ($vis)"
    echo "  SCORE: $score/100   GRADE: $grade"
    echo "  ── dimensions (weight) ──────────────────────────────────"
    printf '  %-9s [%s]  %s\n' "security"  "$(mark "$(jq -r '.dimensions.security.status' <<<"$o")")"  "$(jq -r '.dimensions.security.detail' <<<"$o")  (w35)"
    printf '  %-9s [%s]  %s\n' "metadata"  "$(mark "$(jq -r '.dimensions.metadata.status' <<<"$o")")"  "$(jq -r '.dimensions.metadata.detail' <<<"$o")  (w25)"
    printf '  %-9s [%s]  %s\n' "release"   "$(mark "$(jq -r '.dimensions.release.status' <<<"$o")")"   "$(jq -r '.dimensions.release.detail' <<<"$o")  (w15)"
    printf '  %-9s [%s]  %s\n' "issues"    "$(mark "$(jq -r '.dimensions.issues.status' <<<"$o")")"    "$(jq -r '.dimensions.issues.detail' <<<"$o")  (w15)"
    printf '  %-9s [%s]  %s\n' "actions"   "$(mark "$(jq -r '.dimensions.actions.status' <<<"$o")")"   "$(jq -r '.dimensions.actions.detail' <<<"$o")  (w10)"
    local nf; nf="$(jq -r '.top_fixes | length' <<<"$o")"
    if [ "$nf" -gt 0 ]; then
      echo "  ── top fixes (highest-severity first) ───────────────────"
      jq -r '.top_fixes[] | "     • " + .' <<<"$o"
    fi
  } >&2
}

# ==========================================================================
# Mode dispatch
# ==========================================================================

# Mutually exclusive selectors.
sel=0
[ -n "$REPO" ] && sel=$((sel+1))
[ -n "$ORG" ]  && sel=$((sel+1))
if [ "$sel" -gt 1 ]; then
  echo "repo-scorecard: --repo and --org are mutually exclusive" >&2; exit "$EX_USAGE"
fi

# ---- Fleet sweep ----------------------------------------------------------
if [ -n "$ORG" ]; then
  valid_owner "$ORG" || { echo "repo-scorecard: invalid owner '$ORG'" >&2; exit "$EX_USAGE"; }
  echo "repo-scorecard: sweeping $ORG …" >&2
  list="$(runner gh repo list "$ORG" --no-archived --limit 200 --json nameWithOwner,visibility 2>/dev/null)" \
    || skip "gh repo list failed for $ORG (not authed / offline / rate-limited?)"
  [ -n "$list" ] || skip "no repos returned for $ORG"
  mapfile -t repos < <(printf '%s' "$list" | jq -r '.[].nameWithOwner' | tr -d '\r')
  [ "${#repos[@]}" -gt 0 ] || skip "no non-archived repos for $ORG"

  all="[]"; any_findings=0; swept=0; unread=0; below_min=0
  for r in "${repos[@]}"; do
    valid_repo "$r" || continue
    obj="$(score_repo "$r")"; rc=$?
    if [ "$rc" -eq 7 ] || [ -z "$obj" ] || ! printf '%s' "$obj" | jq -e . >/dev/null 2>&1; then
      unread=$((unread+1))
      [ "$JSON" -eq 1 ] || echo "  ?    $r — couldn't read (skipped)" >&2
      continue
    fi
    swept=$((swept+1))
    [ "$rc" -eq 10 ] && any_findings=1
    all="$(jq -c --argjson o "$obj" '. + [$o]' <<<"$all")"
    sc="$(jq -r '.score' <<<"$obj")"
    if [ -n "$MIN_SCORE" ] && [ "$sc" -lt "$MIN_SCORE" ]; then below_min=$((below_min+1)); fi
    if [ "$JSON" -eq 0 ]; then
      # matrix row: per-dimension single-char marks + score + grade.
      m() { case "$(jq -r ".dimensions.$1.status" <<<"$obj")" in
        ok) printf '+';; warn) printf '~';; gap) printf 'X';; "n/a") printf '?';; *) printf ' ';; esac; }
      printf '  %-34s S:%s M:%s R:%s I:%s A:%s  %3s %s\n' \
        "$r" "$(m security)" "$(m metadata)" "$(m release)" "$(m issues)" "$(m actions)" \
        "$sc" "$(jq -r '.grade' <<<"$obj")" >&2
    fi
  done

  # Roll-up stats. The repo array can be large (a big org), so pipe it via STDIN
  # rather than --argjson on argv — argv has a length cap and a fleet sweep blows
  # past it (observed: jq "Argument list too long" at ~70 repos on MSYS).
  rollup="$(printf '%s' "$all" | jq -c --arg org "$ORG" \
    --argjson swept "$swept" --argjson unread "$unread" \
    '. as $data
     | ($data | map(.score)) as $scores
     | ($scores | length) as $n
     | { org:$org, repos_scored:$swept, repos_unreadable:$unread,
         avg_score: (if $n>0 then (($scores|add)/$n|floor) else null end),
         median_score: (if $n>0 then ($scores|sort|.[($n/2|floor)]) else null end),
         total_open_alerts: ([ $data[].dimensions.security.open_alerts // 0 ] | add),
         failing_by_dimension: {
           security: ([ $data[]|select(.dimensions.security.status=="gap") ]|length),
           metadata: ([ $data[]|select(.dimensions.metadata.status=="gap") ]|length),
           release:  ([ $data[]|select(.dimensions.release.status=="gap") ]|length),
           issues:   ([ $data[]|select(.dimensions.issues.status=="gap") ]|length),
           actions:  ([ $data[]|select(.dimensions.actions.status=="gap") ]|length)
         },
         worst: ([ $data[] | {repo, score, grade} ] | sort_by(.score) | .[0:3])
       }')"

  if [ "$JSON" -eq 1 ]; then
    # Pipe the (large) data array via stdin; $rollup is small enough for --argjson.
    printf '%s' "$all" | jq -c --argjson roll "$rollup" \
      --argjson find "$any_findings" --argjson below "$below_min" \
      --arg minscore "${MIN_SCORE:-}" \
      '{data:., meta:($roll + {findings:($find==1 or $below>0), below_min:$below,
        min_score:(if $minscore=="" then null else ($minscore|tonumber) end),
        schema:"claude-mods.github-ops.repo-scorecard/v1"})}'
  else
    {
      echo "── roll-up: $ORG ───────────────────────────────────────────"
      printf '%s' "$rollup" | jq -r '
        "  scored: \(.repos_scored)   unreadable: \(.repos_unreadable)",
        "  avg score: \(.avg_score)   median: \(.median_score)",
        "  total open security alerts (fleet): \(.total_open_alerts)",
        "  repos with a GAP — security:\(.failing_by_dimension.security) metadata:\(.failing_by_dimension.metadata) release:\(.failing_by_dimension.release) issues:\(.failing_by_dimension.issues) actions:\(.failing_by_dimension.actions)",
        "  worst: " + ([ .worst[] | "\(.repo) (\(.score)/\(.grade))" ] | join(", "))'
      [ -n "$MIN_SCORE" ] && echo "  below --min-score $MIN_SCORE: $below_min repo(s)"
      echo "  legend: +=ok ~=warn X=gap ?=n/a  ·  S=security M=metadata R=release I=issues A=actions"
    } >&2
  fi
  { [ "$any_findings" -eq 1 ] || [ "$below_min" -gt 0 ]; } && exit "$EX_FINDINGS"
  exit "$EX_OK"
fi

# ---- Single repo ----------------------------------------------------------
if [ -z "$REPO" ]; then
  url="$(git remote get-url "$REMOTE" 2>/dev/null)" || skip "no '$REMOTE' remote here"
  case "$url" in
    *github.com[:/]*)
      REPO="$(printf '%s' "$url" | tr -d '\r' | sed -E 's#^.*github\.com[:/]+##; s#\.git$##; s#/$##')" ;;
    *) skip "remote '$REMOTE' is not a github.com repo" ;;
  esac
fi
valid_repo "$REPO" || { echo "repo-scorecard: invalid OWNER/REPO '$REPO'" >&2; exit "$EX_USAGE"; }

obj="$(score_repo "$REPO")"; rc=$?
if [ "$rc" -eq 7 ] || [ -z "$obj" ] || ! printf '%s' "$obj" | jq -e . >/dev/null 2>&1; then
  skip "couldn't read $REPO (not authed / offline / not found / timeout)"
fi

score="$(jq -r '.score' <<<"$obj")"
below=0
if [ -n "$MIN_SCORE" ] && [ "$score" -lt "$MIN_SCORE" ]; then below=1; fi

if [ "$JSON" -eq 1 ]; then
  jq -c --argjson find "$( [ "$rc" -eq 10 ] && echo 1 || echo 0 )" \
    --argjson below "$below" --arg minscore "${MIN_SCORE:-}" \
    '{data:[.], meta:{repo:.repo, visibility:.visibility, score:.score, grade:.grade,
       findings:($find==1 or $below>0), below_min:$below,
       min_score:(if $minscore=="" then null else ($minscore|tonumber) end),
       schema:"claude-mods.github-ops.repo-scorecard/v1"}}' <<<"$obj"
else
  print_card "$obj"
fi

{ [ "$rc" -eq 10 ] || [ "$below" -eq 1 ]; } && exit "$EX_FINDINGS"
exit "$EX_OK"
