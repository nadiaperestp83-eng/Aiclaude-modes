#!/usr/bin/env bash
# Offline self-test for okf-ops scripts. No network. Exits 0 if all pass.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)/scripts"

# Pick a python that actually runs (the Windows Store `python3` stub exits 49).
PYTHON=""
for c in python python3 py; do
    command -v "$c" >/dev/null 2>&1 || continue
    "$c" -c 'import sys' >/dev/null 2>&1 && { PYTHON="$c"; break; }
done
[[ -z "$PYTHON" ]] && { echo "no working python found" >&2; exit 1; }

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
no()  { echo "  FAIL  $1"; fail=$((fail+1)); }
expect_exit() { # label want got
    if [[ "$2" == "$3" ]]; then ok "$1 (exit $3)"; else no "$1 (want $2 got $3)"; fi
}

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

CHECK="$SCRIPTS/check-okf.py"
ASSESS="$SCRIPTS/assess-okf.py"

echo "-- check-okf.py --"
"$PYTHON" "$CHECK" --help >/dev/null 2>&1; expect_exit "--help" 0 $?

# Conformant bundle: one concept with non-empty type + an index.md
mkdir -p "$SB/good"
cat > "$SB/good/a.md" <<'EOF'
---
type: dataset
title: A
---
# A
body
EOF
printf '# Index\n* [A](a.md) - the a concept\n' > "$SB/good/index.md"
"$PYTHON" "$CHECK" "$SB/good" >/dev/null 2>&1; expect_exit "conformant -> 0" 0 $?

# --json envelope is valid + schema present
"$PYTHON" "$CHECK" --json "$SB/good" 2>/dev/null \
  | "$PYTHON" -c "import sys,json;d=json.load(sys.stdin);assert d['meta']['schema']=='claude-mods.okf-ops.check-okf/v1'" \
  && ok "check --json envelope schema" || no "check --json envelope schema"

# Missing type -> non-conformant (10)
mkdir -p "$SB/notype"
cat > "$SB/notype/a.md" <<'EOF'
---
title: no type here
---
# A
EOF
"$PYTHON" "$CHECK" "$SB/notype" >/dev/null 2>&1; expect_exit "missing type -> 10" 10 $?

# Unparseable frontmatter (malformed YAML) -> 4  [only meaningful with PyYAML;
# the fallback parser is lenient, so accept 4 OR 10]
mkdir -p "$SB/bad"
printf -- '---\nkey: "unterminated\n  - : :\n---\n# X\n' > "$SB/bad/a.md"
"$PYTHON" "$CHECK" "$SB/bad" >/dev/null 2>&1; rc=$?
if [[ "$rc" == 4 || "$rc" == 10 ]]; then ok "unparseable frontmatter -> 4/10 (got $rc)"; else no "unparseable frontmatter (want 4 or 10, got $rc)"; fi

# Missing dir -> 3
"$PYTHON" "$CHECK" "$SB/nope-xyz" >/dev/null 2>&1; expect_exit "missing dir -> 3" 3 $?

echo "-- assess-okf.py --"
"$PYTHON" "$ASSESS" --help >/dev/null 2>&1; expect_exit "--help" 0 $?
"$PYTHON" "$ASSESS" "$SB/good" >/dev/null 2>&1; expect_exit "scan -> 0" 0 $?
"$PYTHON" "$ASSESS" --json "$SB/good" 2>/dev/null \
  | "$PYTHON" -c "import sys,json;d=json.load(sys.stdin);assert d['meta']['schema']=='claude-mods.okf-ops.assess-okf/v1';assert 'readiness_pct' in d['data']" \
  && ok "assess --json schema + readiness_pct" || no "assess --json schema + readiness_pct"
"$PYTHON" "$ASSESS" "$SB/nope-xyz" >/dev/null 2>&1; expect_exit "missing dir -> 3" 3 $?

echo
echo "=== $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]]
