#!/usr/bin/env python3
# Rank Playwright tests by flakiness from a JSON report so the agent triages, not eyeballs.
#
# Parses a Playwright JSON report (`--reporter=json`) and surfaces the tests
# worth a human's attention: flaky tests (passed only on retry) first, then
# hard "unexpected" failures. Flaky tests are ranked by retry count desc, then
# total duration desc, because the most-retried, slowest test is the worst
# offender in your queue.
#
# Usage:   triage-flakes.py [OPTIONS] [REPORT]
# Input:   REPORT = path to a Playwright JSON report (positional, default ./results.json)
# Output:  stdout = ranked findings (TSV, or JSON envelope with --json)
# Stderr:  headers, summary, progress, errors
# Exit:    0 parsed fine, no flaky/unexpected tests (clean suite)
#          2 usage, 3 file not found, 4 malformed/not a Playwright report,
#          10 DOMAIN SIGNAL: flaky/unexpected tests present (the thing being triaged)
#
# Examples:
#   npx playwright test --reporter=json > results.json
#   triage-flakes.py results.json
#   triage-flakes.py --outcome all -n 50 results.json
#   triage-flakes.py --json results.json | jq '.data[] | select(.outcome=="flaky")'

import argparse
import json
import sys
from pathlib import Path

SCHEMA = "claude-mods.playwright-ops.flake-triage/v1"

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_VALIDATION = 4
EXIT_FINDINGS = 10

# Rank order for outcomes: flaky always sorts before unexpected.
OUTCOME_RANK = {"flaky": 0, "unexpected": 1}


def err(msg):
    print(msg, file=sys.stderr)


def walk_suites(suites, finds, file_hint=""):
    """Recursively descend the suites tree collecting spec/test results."""
    for suite in suites or []:
        # A suite's file is on the suite node; specs inherit it.
        sfile = suite.get("file") or file_hint
        for spec in suite.get("specs", []) or []:
            collect_spec(spec, finds, sfile)
        walk_suites(suite.get("suites"), finds, sfile)


def collect_spec(spec, finds, sfile):
    title = spec.get("title", "<untitled>")
    sline = spec.get("line", 0)
    sfile = spec.get("file") or sfile
    for test in spec.get("tests", []) or []:
        outcome = test.get("status") or test.get("outcome") or "unknown"
        results = test.get("results", []) or []
        # status sequence ordered by retry index; duration summed across attempts
        ordered = sorted(results, key=lambda r: r.get("retry", 0))
        statuses = [r.get("status", "unknown") for r in ordered]
        duration = sum(int(r.get("duration", 0) or 0) for r in ordered)
        retries = max((r.get("retry", 0) for r in ordered), default=0)
        location = f"{sfile}:{sline}" if sfile else f"?:{sline}"
        finds.append(
            {
                "title": title,
                "location": location,
                "outcome": outcome,
                "retries": retries,
                "statuses": statuses,
                "durationMs": duration,
            }
        )


def load_report(path):
    """Return parsed Playwright report dict, or raise ValueError if not one."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as e:
        raise FileNotFoundError(str(e))
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ValueError(f"not valid JSON: {e}")
    if not isinstance(data, dict) or "suites" not in data:
        raise ValueError("missing top-level 'suites' key - not a Playwright JSON report")
    if not isinstance(data["suites"], list):
        raise ValueError("'suites' is not a list — not a Playwright JSON report")
    return data


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="triage-flakes.py",
        description="Rank Playwright tests by flakiness from a JSON report.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "EXAMPLES:\n"
            "  npx playwright test --reporter=json > results.json\n"
            "  triage-flakes.py results.json\n"
            "  triage-flakes.py --outcome all -n 50 results.json\n"
            "  triage-flakes.py --json results.json | jq '.data[] | select(.outcome==\"flaky\")'\n"
            "\n"
            "EXIT CODES:\n"
            "  0  parsed fine, no flaky/unexpected tests (clean suite)\n"
            "  2  usage   3  file not found   4  malformed report\n"
            "  10 flaky/unexpected tests present (the triage signal)\n"
        ),
    )
    p.add_argument(
        "report",
        nargs="?",
        default="results.json",
        help="path to Playwright JSON report (default: ./results.json)",
    )
    p.add_argument("--json", action="store_true", help="emit a JSON envelope instead of TSV")
    p.add_argument(
        "-n",
        "--limit",
        type=int,
        default=20,
        metavar="N",
        help="cap rows printed (default 20)",
    )
    p.add_argument(
        "--outcome",
        default="flaky,unexpected",
        help="which outcomes to include: flaky | unexpected | all (default flaky,unexpected)",
    )
    args = p.parse_args(argv)

    if args.limit < 0:
        err("ERROR: --limit must be >= 0")
        return EXIT_USAGE

    sel = args.outcome.strip().lower()
    if sel == "all":
        wanted = None  # all outcomes
    else:
        wanted = {x.strip() for x in sel.split(",") if x.strip()}
        unknown = wanted - {"flaky", "unexpected", "expected", "skipped"}
        if unknown:
            err(f"ERROR: unknown outcome(s): {', '.join(sorted(unknown))} (use flaky|unexpected|all)")
            return EXIT_USAGE

    path = Path(args.report).resolve()
    if not path.exists():
        err(f"ERROR: report not found: {path}")
        if args.json:
            print(json.dumps({"error": {"code": "NOT_FOUND", "message": f"report not found: {path}"}}))
        return EXIT_NOT_FOUND
    if not path.is_file():
        err(f"ERROR: not a file: {path}")
        return EXIT_NOT_FOUND

    try:
        data = load_report(path)
    except FileNotFoundError as e:
        err(f"ERROR: cannot read report: {e}")
        return EXIT_NOT_FOUND
    except ValueError as e:
        err(f"ERROR: malformed report: {e}")
        if args.json:
            print(json.dumps({"error": {"code": "VALIDATION", "message": str(e)}}))
        return EXIT_VALIDATION

    finds = []
    walk_suites(data.get("suites"), finds)

    # The domain signal is computed over ALL findings, regardless of the display
    # filter — a clean suite means zero flaky AND zero unexpected, full stop.
    signal_present = any(f["outcome"] in ("flaky", "unexpected") for f in finds)

    if wanted is None:
        shown = list(finds)
    else:
        shown = [f for f in finds if f["outcome"] in wanted]

    # Rank: flaky before unexpected (OUTCOME_RANK), then retries desc, duration desc.
    shown.sort(
        key=lambda f: (
            OUTCOME_RANK.get(f["outcome"], 99),
            -f["retries"],
            -f["durationMs"],
        )
    )

    capped = shown[: args.limit] if args.limit else shown

    total = len(finds)
    flaky_n = sum(1 for f in finds if f["outcome"] == "flaky")
    unexp_n = sum(1 for f in finds if f["outcome"] == "unexpected")
    err(f"=== Flake triage: {path.name} ===")
    err(f"  {total} tests | {flaky_n} flaky | {unexp_n} unexpected | showing {len(capped)} of {len(shown)}")

    if args.json:
        envelope = {
            "data": capped,
            "meta": {
                "count": len(capped),
                "total_matched": len(shown),
                "flaky": flaky_n,
                "unexpected": unexp_n,
                "schema": SCHEMA,
            },
        }
        print(json.dumps(envelope, indent=2))
    else:
        print("outcome\tretries\tstatuses\tduration_ms\tlocation\ttitle")
        for f in capped:
            print(
                f"{f['outcome']}\t{f['retries']}\t{'->'.join(f['statuses'])}\t"
                f"{f['durationMs']}\t{f['location']}\t{f['title']}"
            )

    return EXIT_FINDINGS if signal_present else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
