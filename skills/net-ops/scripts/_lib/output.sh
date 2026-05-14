# net-ops :: _lib/output.sh
# Output mode handling for probe scripts. Supports two modes:
#   - text (default): human-readable [PASS]/[FAIL] lines + summary block
#   - json: newline-delimited JSON, one record per check + a summary record
#
# Usage in a probe script:
#   source "$(dirname "$0")/../_lib/output.sh"
#   parse_output_flags "$@"
#   # then use section / pass / fail as before — they auto-route to the right mode

JSON_MODE="${JSON_MODE:-0}"

parse_output_flags() {
    for a in "$@"; do
        [[ "$a" == "--json" ]] && JSON_MODE=1
    done
}

# JSON-safe string escaper. Handles backslash, double-quote, and control chars.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# These three are the public API. They write either text or JSON depending on mode.
PASS_COUNT=0
FAIL_COUNT=0
FIRST_FAIL=""
CURRENT_SECTION=""

section() {
    CURRENT_SECTION="$1"
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"section","name":"%s"}\n' "$(_json_escape "$1")"
    else
        echo
        echo "=== $1 ==="
    fi
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"check","section":"%s","label":"%s","status":"pass","detail":"%s"}\n' \
            "$(_json_escape "$CURRENT_SECTION")" "$(_json_escape "$1")" "$(_json_escape "${2:-}")"
    else
        echo "[PASS] $1${2:+ :: $2}"
    fi
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    [[ -z "$FIRST_FAIL" ]] && FIRST_FAIL="[$CURRENT_SECTION] $1"
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"check","section":"%s","label":"%s","status":"fail","detail":"%s"}\n' \
            "$(_json_escape "$CURRENT_SECTION")" "$(_json_escape "$1")" "$(_json_escape "${2:-}")"
    else
        echo "[FAIL] $1${2:+ :: $2}"
    fi
}

# Call from end of probe to emit summary record / block.
emit_summary() {
    if [[ "$JSON_MODE" -eq 1 ]]; then
        printf '{"type":"summary","pass":%d,"fail":%d,"first_fail":"%s"}\n' \
            "$PASS_COUNT" "$FAIL_COUNT" "$(_json_escape "$FIRST_FAIL")"
    else
        echo
        echo "=== SUMMARY ==="
        echo "  PASS: $PASS_COUNT    FAIL: $FAIL_COUNT"
        if [[ -n "$FIRST_FAIL" ]]; then
            echo "  First failure: $FIRST_FAIL"
        else
            echo "  No failures."
        fi
    fi
}

# Helper for scripts that want to suppress informational/diagnostic output
# (the non-PASS/FAIL annotations like scutil dumps) in JSON mode.
info() {
    if [[ "$JSON_MODE" -eq 1 ]]; then
        # Optional: emit info records. Keep silent for cleaner JSON parsing.
        return 0
    fi
    echo "$@"
}
