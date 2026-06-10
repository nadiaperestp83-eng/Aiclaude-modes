#!/usr/bin/env bash
# Run every skill's behavioural test suite (skills/*/tests/run.sh).
# Suites are responsible for their own OS gating (exit 0 with a skip
# message on unsupported platforms). Any nonzero exit fails this runner.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

suites=(skills/*/tests/run.sh)
if [ ! -e "${suites[0]}" ]; then
    echo "No skill test suites found (skills/*/tests/run.sh)"
    exit 0
fi

failed=0
total=0
for suite in "${suites[@]}"; do
    total=$((total + 1))
    name="$(basename "$(dirname "$(dirname "$suite")")")"
    echo "=== $name"
    if bash "$suite"; then
        echo "--- $name: PASS"
    else
        rc=$?
        echo "--- $name: FAIL (exit $rc)"
        failed=$((failed + 1))
    fi
    echo
done

echo "Skill test suites: $((total - failed))/$total passed"
[ "$failed" -eq 0 ] || exit 1
