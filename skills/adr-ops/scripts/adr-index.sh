#!/usr/bin/env bash
# Emit the ADR index — one row per record, in number order. Read-only.
#
# Usage:   adr-index.sh [--dir DIR] [--json]
# Input:   argv flags only (no stdin).
# Output:  stdout = the index. Plain: "number | status | date | title" rows.
#          --json: {"data":[...],"meta":{...,"schema":"claude-mods.adr-ops.index/v1"}}
#          Data only — the directory IS the index; this is just a parse of it.
# Stderr:  headers, warnings (e.g. yq absent -> fallback parser), errors.
# Exit:    0 ok, 2 usage, 3 dir not found
#
# Prefers `yq --front-matter=extract` for frontmatter parsing; degrades to a
# sed/grep parser when yq is absent (announced on stderr).
#
# Examples:
#   adr-index.sh
#   adr-index.sh --dir docs/decisions
#   adr-index.sh --json | jq '.data[] | select(.status=="accepted")'
set -uo pipefail

readonly EX_OK=0 EX_USAGE=2 EX_NOTFOUND=3

DIR="docs/adr"
JSON=0

usage() {
  cat <<'EOF'
adr-index.sh — emit the ADR index (number | status | date | title), in order.

Usage:
  adr-index.sh [--dir DIR] [--json]

Options:
  --dir DIR    ADR directory (default: docs/adr)
  --json       Emit a JSON envelope (schema claude-mods.adr-ops.index/v1)
  -h, --help   Show this help and exit 0.

Exit codes:
  0 ok   2 usage   3 dir not found

Examples:
  adr-index.sh
  adr-index.sh --dir docs/decisions
  adr-index.sh --json | jq '.data[] | select(.status=="accepted")'
EOF
}

die_usage() { printf 'error: %s\n' "$1" >&2; echo >&2; usage >&2; exit "$EX_USAGE"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)     [[ $# -ge 2 ]] || die_usage "--dir needs a value"; DIR="$2"; shift 2 ;;
    --json)    JSON=1; shift ;;
    -h|--help) usage; exit "$EX_OK" ;;
    -*)        die_usage "unknown flag: $1" ;;
    *)         die_usage "unexpected positional argument: $1" ;;
  esac
done

[[ -d "$DIR" ]] || { printf 'error: ADR directory not found: %s\n' "$DIR" >&2; exit "$EX_NOTFOUND"; }

HAVE_YQ=0
if command -v yq >/dev/null 2>&1; then HAVE_YQ=1; else
  printf 'note: yq not found — using built-in frontmatter parser.\n' >&2
fi

# Extract a scalar frontmatter field from a file.
#   field_of <file> <field>
field_of() {
  local file="$1" field="$2"
  if [[ "$HAVE_YQ" -eq 1 ]]; then
    local v
    v="$(yq --front-matter=extract ".$field" "$file" 2>/dev/null)"
    [[ "$v" == "null" ]] && v=""
    printf '%s' "$v"
  else
    # Read only the first frontmatter block (between the first two --- lines).
    awk -v f="$field" '
      NR==1 && $0=="---" { infm=1; next }
      infm && $0=="---" { exit }
      infm {
        if ($0 ~ "^" f ":[[:space:]]*") {
          sub("^" f ":[[:space:]]*", "")
          gsub(/^["'"'"']|["'"'"']$/, "")
          print
          exit
        }
      }
    ' "$file"
  fi
}

title_of() {
  # First "# ADR-NNN: Title" line, with the prefix stripped.
  sed -n 's/^# ADR-[0-9]*:[[:space:]]*//p' "$1" | head -1
}

# Collect ADR files in number order.
rows_num=(); rows_status=(); rows_date=(); rows_title=()
shopt -s nullglob
mapfile -t files < <(
  for f in "$DIR"/ADR-*.md; do
    base="$(basename "$f")"
    [[ "$base" =~ ^ADR-([0-9]+) ]] || continue
    printf '%010d\t%s\n' "$((10#${BASH_REMATCH[1]}))" "$f"
  done | sort | cut -f2-
)
shopt -u nullglob

for f in "${files[@]}"; do
  base="$(basename "$f")"
  [[ "$base" =~ ^(ADR-[0-9]+) ]] || continue
  num="${BASH_REMATCH[1]}"
  rows_num+=("$num")
  rows_status+=("$(field_of "$f" status)")
  rows_date+=("$(field_of "$f" date)")
  rows_title+=("$(title_of "$f")")
done

count="${#rows_num[@]}"

if [[ "$JSON" -eq 1 ]]; then
  # Build JSON without external deps (escape backslash + double-quote).
  esc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
  printf '{"data":['
  for ((i=0; i<count; i++)); do
    [[ $i -gt 0 ]] && printf ','
    printf '{"number":"%s","status":"%s","date":"%s","title":"%s"}' \
      "$(esc "${rows_num[$i]}")" "$(esc "${rows_status[$i]}")" \
      "$(esc "${rows_date[$i]}")" "$(esc "${rows_title[$i]}")"
  done
  printf '],"meta":{"count":%d,"dir":"%s","schema":"claude-mods.adr-ops.index/v1"}}\n' \
    "$count" "$(esc "$DIR")"
else
  for ((i=0; i<count; i++)); do
    printf '%s | %s | %s | %s\n' \
      "${rows_num[$i]}" "${rows_status[$i]}" "${rows_date[$i]}" "${rows_title[$i]}"
  done
fi

exit "$EX_OK"
