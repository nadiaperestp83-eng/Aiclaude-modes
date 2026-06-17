#!/usr/bin/env bash
# Self-test for windows-ops — terminal-design adoption + (where pwsh exists)
# runtime ASCII purity of the shared framing.
#
# Static checks run everywhere. The dynamic PowerShell checks need `pwsh`; on a
# host without it (e.g. a Linux CI runner) they skip cleanly, like the mac-ops /
# net-ops suites gate on their platform.
#
# Usage:   bash tests/run.sh
# Exit:    0 all pass (or dynamic checks skipped), 1 a failure

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$HERE")"
SCRIPTS="$SKILL/scripts"
COMMON="$SCRIPTS/_lib/common.ps1"
TERMPS1="$SKILL/../_lib/term.ps1"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "=== windows-ops self-test ==="

# ── static: term.ps1 adoption (the lever for every script via common.ps1) ──
echo "-- terminal design system --"
grep -q 'term\.ps1' "$COMMON" && ok "common.ps1 sources shared term.ps1" || no "common.ps1 does not source term.ps1"
[ -f "$TERMPS1" ] && ok "term.ps1 present" || no "term.ps1 missing at $TERMPS1"
# Framing routes through term.ps1's Get-TermColor, not hand-rolled host coloring.
grep -q 'Get-TermColor' "$COMMON" && ok "common.ps1 framing uses Get-TermColor" || no "common.ps1 does not use Get-TermColor"

# ── dynamic: needs PowerShell; skip cleanly where absent ───────────────────
PWSH=""
for c in pwsh powershell; do command -v "$c" >/dev/null 2>&1 && { PWSH="$c"; break; }; done
if [ -z "$PWSH" ]; then
  echo "  (pwsh not found — skipping dynamic PowerShell checks)"
  echo "=== $PASS passed, $FAIL failed ==="
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

# Resolve a path PowerShell can open (convert MSYS -> Windows when needed).
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
WCOMMON="$(winpath "$COMMON")"

# common.ps1 framing is ASCII-pure under TERM_ASCII=1 FORCE_COLOR=1 (principle #3).
out="$(TERM_ASCII=1 FORCE_COLOR=1 "$PWSH" -NoProfile -Command ". '$WCOMMON'; Write-Section 'DISK'; Write-Log PASS 'ok'; Write-Log FAIL 'bad'; Write-Log WARN 'hot'" 2>&1)"
if printf '%s' "$out" | LC_ALL=C grep -q '[^[:print:][:cntrl:]]'; then
  no "common.ps1 framing emits non-ASCII under TERM_ASCII=1"
else ok "common.ps1 framing pure ASCII under TERM_ASCII=1"; fi
# Color is applied under FORCE_COLOR (ESC present).
cout="$(FORCE_COLOR=1 "$PWSH" -NoProfile -Command ". '$WCOMMON'; Write-Log PASS 'ok'" 2>&1)"
case "$cout" in *$'\033'*) ok "common.ps1 colorizes under FORCE_COLOR";; *) no "common.ps1 did not colorize under FORCE_COLOR";; esac
# The [TAG] text stays literal/greppable (color is amplification, not the signal).
case "$cout" in *'[PASS]'*) ok "common.ps1 keeps the [PASS] tag literal";; *) no "common.ps1 lost the [PASS] tag";; esac

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
