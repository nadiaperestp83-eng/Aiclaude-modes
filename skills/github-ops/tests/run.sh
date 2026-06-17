#!/usr/bin/env bash
# Offline self-test for github-ops scripts. No network required — exercises the
# contract + the gate-safety skip paths (graceful exit 7), not live GitHub data.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPTS="$ROOT/scripts"
CI="$SCRIPTS/check-issues.sh"
SP="$SCRIPTS/check-security-posture.sh"

pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1 (exit $3)"; else no "$1 (want $2 got $3)"; fi; }

echo "-- check-issues.sh (offline contract + skip paths) --"

bash -n "$CI" && ok "bash -n clean" || no "bash -n"

bash "$CI" --help >/dev/null 2>&1; expect "--help" 0 $?
bash "$CI" --frobnicate >/dev/null 2>&1; expect "unknown flag -> usage" 2 $?

# Non-github remote must skip with exit 7 and NEVER hit the network.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git -C "$T" init -q
git -C "$T" remote add origin "/some/local/path.git"
( cd "$T" && bash "$CI" --remote origin >/dev/null 2>&1 ); expect "non-github remote -> unavailable" 7 $?

# Advisory mode on a non-github remote must be SILENT (no stderr) and exit 7 —
# this is the gate-safety contract: an unusable check never disturbs a push.
out="$( cd "$T" && bash "$CI" --advisory --remote origin 2>&1 )"; rc=$?
if [ "$rc" -eq 7 ] && [ -z "$out" ]; then ok "advisory non-github -> silent exit 7"
else no "advisory non-github (rc=$rc, stderr='$out')"; fi

# Missing remote -> skip 7 (git remote get-url fails; no network).
( cd "$T" && bash "$CI" --remote nope-xyz >/dev/null 2>&1 ); expect "missing remote -> unavailable" 7 $?

echo
echo "-- check-security-posture.sh (offline contract + skip paths) --"

bash -n "$SP" && ok "sp: bash -n clean" || no "sp: bash -n"

bash "$SP" --help >/dev/null 2>&1; expect "sp: --help" 0 $?
# --help must advertise EXAMPLES so the tool is discoverable.
if bash "$SP" --help 2>&1 | grep -q "Examples:"; then ok "sp: --help has EXAMPLES"
else no "sp: --help missing EXAMPLES"; fi

bash "$SP" --frobnicate >/dev/null 2>&1; expect "sp: unknown flag -> usage" 2 $?
# Malformed OWNER/REPO is a usage error, never a network call.
bash "$SP" --repo "not-a-valid-spec" >/dev/null 2>&1; expect "sp: bad --repo shape -> usage" 2 $?
# --repo and --org are mutually exclusive.
bash "$SP" --repo a/b --org c >/dev/null 2>&1; expect "sp: --repo + --org -> usage" 2 $?

# Non-github remote must skip with exit 7 and NEVER hit the network.
( cd "$T" && bash "$SP" --remote origin >/dev/null 2>&1 ); expect "sp: non-github remote -> unavailable" 7 $?
# Advisory mode on a non-github remote must be SILENT and exit 7.
out="$( cd "$T" && bash "$SP" --advisory --remote origin 2>&1 )"; rc=$?
if [ "$rc" -eq 7 ] && [ -z "$out" ]; then ok "sp: advisory non-github -> silent exit 7"
else no "sp: advisory non-github (rc=$rc, stderr='$out')"; fi
# Missing remote -> skip 7.
( cd "$T" && bash "$SP" --remote nope-xyz >/dev/null 2>&1 ); expect "sp: missing remote -> unavailable" 7 $?

# --commands emits the review banner on stderr (offline path: banner prints before
# any network work would, on a non-github remote it still skips — so assert the
# banner via the bundled help text instead, which is fully offline).
# The review banner string must be present in the source contract.
if grep -q "review before running — these change repo settings" "$SP"; then ok "sp: review banner string present"
else no "sp: review banner missing"; fi

# The SECURITY.md template asset must exist and be non-trivial.
if [ -s "$ROOT/assets/SECURITY.md.template" ] && grep -q "Reporting a Vulnerability" "$ROOT/assets/SECURITY.md.template"; then
  ok "sp: SECURITY.md.template asset present"
else no "sp: SECURITY.md.template asset missing/empty"; fi

# Read-only guarantee. The ONLY executor in this script is `runner gh api …`
# (every -X PUT/PATCH lives inside an emitted *_cmd string, never executed). Assert
# no `runner gh api` invocation carries a mutating verb.
if grep -E 'runner gh api' "$SP" | grep -Eq '\-X (PUT|PATCH|POST|DELETE)'; then
  no "sp: found an executed mutating gh api call (must be read-only)"
else ok "sp: no executed mutating gh api call (read-only)"; fi
# And every mutating verb that DOES appear must be inside a quoted command string
# (assigned to a *_cmd var), proving it is emitted-as-text only.
if grep -nE '\-X (PUT|PATCH|POST|DELETE)' "$SP" | grep -vqE '_cmd='; then
  no "sp: a mutating verb appears outside an emitted *_cmd string"
else ok "sp: all mutating verbs are emitted text only"; fi

echo
echo "-- repo-scorecard.sh (offline contract + orchestration + read-only proof) --"

RS="$SCRIPTS/repo-scorecard.sh"

bash -n "$RS" && ok "rs: bash -n clean" || no "rs: bash -n"

bash "$RS" --help >/dev/null 2>&1; expect "rs: --help" 0 $?
if bash "$RS" --help 2>&1 | grep -q "Examples:"; then ok "rs: --help has EXAMPLES"
else no "rs: --help missing EXAMPLES"; fi
# The scoring rubric must be documented in the header (transparent, auditable).
if bash "$RS" --help 2>&1 | grep -q "SCORING MODEL"; then ok "rs: --help documents SCORING MODEL"
else no "rs: --help missing SCORING MODEL"; fi

bash "$RS" --frobnicate >/dev/null 2>&1; expect "rs: unknown flag -> usage" 2 $?
# Malformed OWNER/REPO is a usage error, never a network call.
bash "$RS" --repo "not-a-valid-spec" >/dev/null 2>&1; expect "rs: bad --repo shape -> usage" 2 $?
# --repo and --org are mutually exclusive.
bash "$RS" --repo a/b --org c >/dev/null 2>&1; expect "rs: --repo + --org -> usage" 2 $?
# --min-score must be an integer.
bash "$RS" --min-score xx >/dev/null 2>&1; expect "rs: bad --min-score -> usage" 2 $?

# Non-github remote must skip with exit 7 and NEVER hit the network.
( cd "$T" && bash "$RS" --remote origin >/dev/null 2>&1 ); expect "rs: non-github remote -> unavailable" 7 $?
# Missing remote -> skip 7.
( cd "$T" && bash "$RS" --remote nope-xyz >/dev/null 2>&1 ); expect "rs: missing remote -> unavailable" 7 $?

# Orchestration: it MUST call the sibling auditors by name (the reuse is the point).
if grep -q "check-security-posture.sh" "$RS"; then ok "rs: references check-security-posture.sh"
else no "rs: does not reference check-security-posture.sh"; fi
if grep -q "check-issues.sh" "$RS"; then ok "rs: references check-issues.sh"
else no "rs: does not reference check-issues.sh"; fi

# Read-only guarantee: no executed mutating gh verb anywhere. Every gh call must
# be a GET (the remediation pointers it prints are text, not executed). Assert no
# `gh api -X PUT/PATCH/POST/DELETE` and no `gh repo edit`/`gh release create` etc.
if grep -E '\bgh (api )?-X (PUT|PATCH|POST|DELETE)' "$RS" | grep -vqE '^\s*#'; then
  no "rs: found an executed mutating gh -X call (must be read-only)"
else ok "rs: no executed mutating gh -X call (read-only)"; fi
# Belt-and-braces: every `runner gh …` (the only network executor) is a read-only
# subcommand — `gh api <GET path>` or `gh repo list`. No mutating subcommand runs.
if grep -nE 'runner gh ' "$RS" | grep -Evq 'runner gh (api|repo list)'; then
  no "rs: a 'runner gh' call uses a non-read-only subcommand"
else ok "rs: every executed 'runner gh' is read-only (api / repo list)"; fi
# And mutating gh subcommands, where they appear, are inside printed fix strings only
# (the remediation pointers), never executed. Verify they sit on addfix/echo lines.
if grep -nE 'gh (release create|repo edit|release delete|secret set|pr merge)' "$RS" \
     | grep -vqE 'addfix|→'; then
  no "rs: a mutating gh subcommand appears outside a printed remediation string"
else ok "rs: mutating gh subcommands only appear as printed remediation text"; fi

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
