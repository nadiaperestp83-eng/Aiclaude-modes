#!/usr/bin/env bash
# Self-test for adr-ops scripts (adr-new.sh, adr-index.sh, adr-lint.py).
#
# Offline-deterministic (no network). Builds throwaway ADR fixtures, asserts the
# documented exit codes and key output of each script, then cleans up. Resolves
# paths relative to itself so it works both in the repo and once installed to
# ~/.claude/skills/adr-ops/.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass, 1 one or more failures

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCRIPTS="$SKILL/scripts"
NEW="$SCRIPTS/adr-new.sh"
INDEX="$SCRIPTS/adr-index.sh"
LINT="$SCRIPTS/adr-lint.py"

# Pick a python that actually executes — skips the Windows Store `python3` stub.
PYTHON=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done
[[ -z "$PYTHON" ]] && { echo "no working python found" >&2; exit 1; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_exit() { [[ "$2" == "$3" ]] && ok "$1 (exit $3)" || no "$1 (want $2 got $3)"; }
expect_has()  { case "$3" in *"$2"*) ok "$1";; *) no "$1 (missing '$2')";; esac; }

# Write a minimal conformant ADR.
#   make_adr <dir> <NNN> <slug> <status> <date> <supersedes-yaml> <superseded-by-yaml>
make_adr() {
  local dir="$1" nnn="$2" slug="$3" status="$4" date="$5" sup="$6" supby="$7"
  cat > "$dir/ADR-$nnn-$slug.md" <<EOF
---
status: $status
date: $date
supersedes: $sup
superseded-by: $supby
touches:
  - "src/x.py"
---

# ADR-$nnn: $slug Title

## Decision (one sentence)

The system does the $slug thing by default.

## Context

Some forces were in play.

## Alternatives considered

We considered nothing and it lost.

## Consequences

### Positive
- Good.

### Negative
- Cost.

### Non-goals
- Not that.

## See also

- src/x.py
EOF
}

echo "=== adr-ops self-test (python: $PYTHON) ==="

# ── --help contracts (exit 0) ──────────────────────────────────────────────
echo "-- --help --"
bash "$NEW"   --help >/dev/null 2>&1; expect_exit "adr-new --help" 0 $?
bash "$INDEX" --help >/dev/null 2>&1; expect_exit "adr-index --help" 0 $?
"$PYTHON" "$LINT" --help >/dev/null 2>&1; expect_exit "adr-lint --help" 0 $?

# ── adr-lint.py: clean conformant pair -> 0 ────────────────────────────────
echo "-- adr-lint: clean --"
CLEAN="$SB/clean"; mkdir -p "$CLEAN"
make_adr "$CLEAN" 001 alpha accepted 2026-01-01 "[]" "[]"
make_adr "$CLEAN" 002 beta  accepted 2026-01-02 "[]" "[]"
"$PYTHON" "$LINT" --dir "$CLEAN" >/dev/null 2>&1; expect_exit "clean pair -> 0" 0 $?

# ── adr-lint.py: missing dir -> 3 ──────────────────────────────────────────
"$PYTHON" "$LINT" --dir "$SB/no-such-dir" >/dev/null 2>&1; expect_exit "missing dir -> 3" 3 $?

# ── adr-lint.py: missing required field -> 10 ──────────────────────────────
echo "-- adr-lint: findings --"
MISS="$SB/missing"; mkdir -p "$MISS"
cat > "$MISS/ADR-001-x.md" <<'EOF'
---
status: accepted
date: 2026-01-01
superseded-by: []
touches:
  - "a"
---

# ADR-001: X

## Decision (one sentence)

Rule.

## Context
## Alternatives considered
## Consequences
## See also
EOF
out="$("$PYTHON" "$LINT" --dir "$MISS" 2>&1)"; rc=$?
expect_exit "missing 'supersedes' field -> 10" 10 "$rc"
expect_has  "names missing field" "supersedes" "$out"

# ── adr-lint.py: bad status -> 10 ──────────────────────────────────────────
BADS="$SB/badstatus"; mkdir -p "$BADS"
make_adr "$BADS" 001 x bogus 2026-01-01 "[]" "[]"
out="$("$PYTHON" "$LINT" --dir "$BADS" 2>&1)"; rc=$?
expect_exit "bad status -> 10" 10 "$rc"
expect_has  "flags bad status" "not in" "$out"

# ── adr-lint.py: broken supersession (one-sided) -> 10 ─────────────────────
BROKE="$SB/broken-sup"; mkdir -p "$BROKE"
# 002 supersedes 001, but 001 was NOT flipped (still accepted, empty superseded-by).
make_adr "$BROKE" 001 old accepted 2026-01-01 "[]" "[]"
make_adr "$BROKE" 002 new accepted 2026-01-02 "[ADR-001]" "[]"
out="$("$PYTHON" "$LINT" --dir "$BROKE" 2>&1)"; rc=$?
expect_exit "broken supersession -> 10" 10 "$rc"
expect_has  "flags one-sided supersession" "superseded-by" "$out"

# ── adr-lint.py: a properly-flipped supersession pair is clean -> 0 ─────────
GOODSUP="$SB/good-sup"; mkdir -p "$GOODSUP"
make_adr "$GOODSUP" 001 old superseded 2026-01-01 "[]" "[ADR-002]"
make_adr "$GOODSUP" 002 new accepted   2026-01-02 "[ADR-001]" "[]"
"$PYTHON" "$LINT" --dir "$GOODSUP" >/dev/null 2>&1; expect_exit "valid supersession pair -> 0" 0 $?

# ── adr-lint.py: duplicate number -> 10 ────────────────────────────────────
DUP="$SB/dup"; mkdir -p "$DUP"
make_adr "$DUP" 001 a accepted 2026-01-01 "[]" "[]"
make_adr "$DUP" 001 b accepted 2026-01-02 "[]" "[]"
out="$("$PYTHON" "$LINT" --dir "$DUP" 2>&1)"; rc=$?
expect_exit "duplicate number -> 10" 10 "$rc"
expect_has  "flags duplicate" "duplicate ADR number" "$out"

# ── adr-lint.py: unparseable frontmatter -> 4 ──────────────────────────────
BADFM="$SB/badfm"; mkdir -p "$BADFM"
printf '# ADR-001: No Frontmatter\n\n## Decision (one sentence)\nRule.\n' > "$BADFM/ADR-001-x.md"
"$PYTHON" "$LINT" --dir "$BADFM" >/dev/null 2>&1; expect_exit "no frontmatter fence -> 4" 4 $?

# ── adr-lint.py: --json envelope ───────────────────────────────────────────
out="$("$PYTHON" "$LINT" --dir "$DUP" --json 2>/dev/null)"
expect_has "json envelope schema" "claude-mods.adr-ops.lint/v1" "$out"

# ── adr-new.sh: computes next number, derives slug ─────────────────────────
echo "-- adr-new --"
NEWDIR="$SB/newdir"; mkdir -p "$NEWDIR"
make_adr "$NEWDIR" 001 alpha accepted 2026-01-01 "[]" "[]"
make_adr "$NEWDIR" 007 gamma accepted 2026-01-02 "[]" "[]"
out="$(bash "$NEW" --dir "$NEWDIR" --title "Cache The Things" --date 2026-02-02 2>/dev/null)"; rc=$?
expect_exit "adr-new -> 0" 0 "$rc"
expect_has  "next number is highest+1 (008)" "ADR-008-cache-the-things.md" "$out"
[[ -f "$NEWDIR/ADR-008-cache-the-things.md" ]] && ok "file written" || no "file not written"
# the written file passes the linter
"$PYTHON" "$LINT" --dir "$NEWDIR" >/dev/null 2>&1; expect_exit "scaffolded file lints clean -> 0" 0 $?

# ── adr-new.sh: refuses to overwrite -> 5 ──────────────────────────────────
# A pre-existing target must never be clobbered. Create one (ADR-004 already on
# disk), then ask adr-new to write that exact slot via --number — the precondition
# guard must refuse. (--number also exercises the explicit-number override path.)
OWDIR="$SB/overwrite"; mkdir -p "$OWDIR"
make_adr "$OWDIR" 004 collide accepted 2026-01-01 "[]" "[]"
bash "$NEW" --dir "$OWDIR" --title "Collide" --slug collide --number 4 --date 2026-02-02 >/dev/null 2>&1
expect_exit "refuse overwrite -> 5" 5 $?
# --number on a free slot writes there (and lints clean).
bash "$NEW" --dir "$OWDIR" --title "Backfill Two" --slug backfill-two --number 2 --date 2026-02-02 >/dev/null 2>&1
expect_exit "--number free slot writes -> 0" 0 $?
[[ -f "$OWDIR/ADR-002-backfill-two.md" ]] && ok "--number wrote ADR-002" || no "--number did not write ADR-002"

# ── adr-new.sh: --dry-run writes nothing ───────────────────────────────────
DRY="$SB/dry"; mkdir -p "$DRY"
before="$(ls "$DRY" | wc -l)"
out="$(bash "$NEW" --dir "$DRY" --title "Dry Run Test" --dry-run 2>/dev/null)"; rc=$?
expect_exit "dry-run -> 0" 0 "$rc"
after="$(ls "$DRY" | wc -l)"
[[ "$before" == "$after" ]] && ok "dry-run wrote nothing" || no "dry-run wrote a file"
expect_has "dry-run prints target path" "ADR-001-dry-run-test.md" "$out"

# ── adr-new.sh: bad status -> 2, missing title -> 2 ────────────────────────
bash "$NEW" --dir "$NEWDIR" --title "X" --status nonsense >/dev/null 2>&1; expect_exit "bad status -> 2" 2 $?
bash "$NEW" --dir "$NEWDIR" >/dev/null 2>&1; expect_exit "missing title -> 2" 2 $?
bash "$NEW" --dir "$SB/no-such" --title "X" >/dev/null 2>&1; expect_exit "missing dir -> 3" 3 $?

# ── adr-new.sh: --apply-supersede flips the old record ─────────────────────
SUPDIR="$SB/supdir"; mkdir -p "$SUPDIR"
make_adr "$SUPDIR" 001 router accepted 2026-01-01 "[]" "[]"
bash "$NEW" --dir "$SUPDIR" --title "New Router" --supersedes ADR-001 --apply-supersede --date 2026-03-03 >/dev/null 2>&1
expect_exit "apply-supersede -> 0" 0 $?
"$PYTHON" "$LINT" --dir "$SUPDIR" >/dev/null 2>&1
expect_exit "auto-flipped pair lints clean -> 0" 0 $?

# ── adr-index.sh: one row per ADR, in order ────────────────────────────────
echo "-- adr-index --"
out="$(bash "$INDEX" --dir "$CLEAN" 2>/dev/null)"; rc=$?
expect_exit "adr-index -> 0" 0 "$rc"
lines="$(printf '%s\n' "$out" | grep -c '^ADR-')"
[[ "$lines" == 2 ]] && ok "two ADRs -> two rows" || no "expected 2 rows, got $lines"
expect_has "row carries status" "accepted" "$out"
bash "$INDEX" --dir "$SB/no-such-dir" >/dev/null 2>&1; expect_exit "missing dir -> 3" 3 $?
out="$(bash "$INDEX" --dir "$CLEAN" --json 2>/dev/null)"
expect_has "json envelope schema" "claude-mods.adr-ops.index/v1" "$out"

# ── summary ────────────────────────────────────────────────────────────────
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
