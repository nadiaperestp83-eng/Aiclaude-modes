#!/usr/bin/env bash
# Offline self-test for github-ops scripts. No network required — exercises the
# contract + the gate-safety skip paths (graceful exit 7), not live GitHub data.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)/scripts"
CI="$SCRIPTS/check-issues.sh"

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
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
