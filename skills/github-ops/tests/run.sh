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
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
