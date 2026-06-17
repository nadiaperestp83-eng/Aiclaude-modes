#!/usr/bin/env python3
# Lint a hooks.json (or the "hooks" block of a settings.json) against the
# current Claude Code hook contract. Offline / structural only — no network.
#
# Usage:   validate-hooks-json.py [--json] [--strict] [PATH]
# Input:   PATH to a hooks.json or settings.json (positional). Default: the
#          repo's hooks/hooks.json if present (resolved from cwd or git root).
# Output:  stdout = findings (plain text, or JSON envelope with --json) — data only
# Stderr:  headers, progress, per-finding human framing, summary, errors
# Exit:    0 clean, 2 usage, 3 file-not-found, 4 malformed-JSON,
#          10 findings present (DOMAIN SIGNAL — "ran fine, found issues")
#
# --strict makes warnings count toward exit 10 (default: only errors do).
#
# The 30-event catalog and the matcher/hook-type/output rules enforced here
# are derived from the authoritative reference shipped alongside this script:
#   ../references/hooks-reference.md  (the Event Catalog + Hook Types tables).
# Keep KNOWN_EVENTS / HOOK_TYPES in sync with that file when the contract moves.
#
# Examples:
#   validate-hooks-json.py hooks/hooks.json
#   validate-hooks-json.py --json .claude/settings.json | jq '.data[]'
#   validate-hooks-json.py --strict ./hooks.json   # warnings also fail

import argparse
import json
import os
import subprocess
import sys

# Windows consoles default to cp1252; force UTF-8 so glyphs/em-dashes in framing
# don't raise UnicodeEncodeError (the repo's standard fix).
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    except (AttributeError, ValueError):
        pass


class Term:
    """Tiny ANSI helper mirroring skills/_lib/term.sh (bash-only; per
    TERMINAL-DESIGN.md §9 the Python port is inline). Honors FORCE_COLOR /
    NO_COLOR / TERM_ASCII; ASCII glyph fallback on TERM_ASCII or a non-UTF stream."""

    _C = {"green": "\033[32m", "yellow": "\033[33m", "orange": "\033[38;5;208m",
          "red": "\033[31m", "cyan": "\033[36m", "dim": "\033[2m", "off": "\033[0m"}
    _GLYPH = {"ok": "✓", "bad": "✗", "warn": "▲", "skip": "—", "na": "—", "unknown": "?"}
    _ASCII = {"ok": "+", "bad": "x", "warn": "!", "skip": "-", "na": "-", "unknown": "?"}
    _MARK_COLOR = {"ok": "green", "bad": "red", "warn": "orange", "skip": "dim",
                   "na": "dim", "unknown": "yellow"}

    def __init__(self, stream=sys.stderr):
        enc = (getattr(stream, "encoding", "") or "").lower()
        self.ascii = (os.environ.get("TERM_ASCII") == "1"
                      or os.environ.get("FLEET_ASCII") == "1" or "utf" not in enc)
        if os.environ.get("FORCE_COLOR"):
            self.color = True
        elif (os.environ.get("NO_COLOR") is not None or os.environ.get("TERM") == "dumb"
              or not getattr(stream, "isatty", lambda: False)()):
            self.color = False
        else:
            self.color = True

    def c(self, name, text):
        return f"{self._C.get(name, '')}{text}{self._C['off']}" if self.color else text

    def mark(self, state):
        return self.c(self._MARK_COLOR.get(state, ""),
                      (self._ASCII if self.ascii else self._GLYPH).get(state, "."))

    def hdr(self, text):
        return self.c("cyan", f"=== {text} ===")


TERM = Term(sys.stderr)

SCHEMA = "claude-mods.claude-code-ops.hooks-lint/v1"

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_NOT_FOUND = 3
EXIT_MALFORMED = 4
EXIT_FINDINGS = 10

# --- Source of truth: ../references/hooks-reference.md "Event Catalog" table. ---
# The 30 hook events Claude Code recognises (June 2026 contract). An event key
# outside this set is a finding — almost always a typo or a stale name.
KNOWN_EVENTS = [
    "SessionStart", "SessionEnd", "Setup",
    "UserPromptSubmit", "UserPromptExpansion",
    "PreToolUse", "PermissionRequest", "PermissionDenied",
    "PostToolUse", "PostToolUseFailure", "PostToolBatch",
    "Stop", "StopFailure",
    "SubagentStart", "SubagentStop",
    "TaskCreated", "TaskCompleted",
    "TeammateIdle", "Notification", "MessageDisplay",
    "ConfigChange", "CwdChanged", "FileChanged",
    "PreCompact", "PostCompact",
    "InstructionsLoaded",
    "WorktreeCreate", "WorktreeRemove",
    "Elicitation", "ElicitationResult",
]  # len == 30

# Source of truth: ../references/hooks-reference.md "Hook Types" section.
HOOK_TYPES = ["command", "http", "mcp_tool", "prompt", "agent"]

# Portability-recommended placeholders for command paths.
ROOTED_PLACEHOLDERS = ("${CLAUDE_PLUGIN_ROOT}", "${CLAUDE_PROJECT_DIR}",
                       "${CLAUDE_PLUGIN_DATA}", "${CLAUDE_SKILL_DIR}")


class Finding:
    __slots__ = ("pointer", "severity", "message")

    def __init__(self, pointer, severity, message):
        self.pointer = pointer
        self.severity = severity  # "error" | "warning"
        self.message = message

    def as_dict(self):
        return {"pointer": self.pointer, "severity": self.severity,
                "message": self.message}


def add(findings, pointer, severity, message):
    findings.append(Finding(pointer, severity, message))


def looks_like_permission_rule(s):
    # Permission-rule syntax: "Tool(args)" e.g. Bash(git *), Edit(*.ts).
    if not isinstance(s, str) or "(" not in s or not s.endswith(")"):
        return False
    head = s.split("(", 1)[0]
    return bool(head) and head[0].isalpha()


def check_hook_entry(findings, entry, ptr):
    if not isinstance(entry, dict):
        add(findings, ptr, "error",
            "hook entry must be an object, got %s" % type(entry).__name__)
        return
    htype = entry.get("type")
    if htype is None:
        add(findings, ptr, "error", "hook entry missing 'type'")
    elif htype not in HOOK_TYPES:
        add(findings, ptr, "error",
            "unknown hook type %r (expected one of: %s)"
            % (htype, ", ".join(HOOK_TYPES)))

    if htype == "command":
        cmd = entry.get("command")
        if not cmd or not isinstance(cmd, str):
            add(findings, ptr, "error",
                "command hook must have a non-empty string 'command'")
        elif not any(p in cmd for p in ROOTED_PLACEHOLDERS):
            add(findings, ptr, "warning",
                "command path is not rooted at ${CLAUDE_PLUGIN_ROOT}/"
                "${CLAUDE_PROJECT_DIR} — may break when cwd varies")
    elif htype == "http":
        if not entry.get("url"):
            add(findings, ptr, "error", "http hook must have a 'url'")
    elif htype == "mcp_tool":
        if not entry.get("server") or not entry.get("tool"):
            add(findings, ptr, "error",
                "mcp_tool hook must have 'server' and 'tool'")
    elif htype in ("prompt", "agent"):
        if not entry.get("prompt"):
            add(findings, ptr, "warning",
                "%s hook usually needs a 'prompt'" % htype)

    iff = entry.get("if")
    if iff is not None:
        if not isinstance(iff, str):
            add(findings, ptr, "error", "'if' filter must be a string")
        elif not looks_like_permission_rule(iff):
            add(findings, ptr, "warning",
                "'if' filter %r does not look like a permission rule "
                "(e.g. \"Bash(git *)\", \"Edit(*.ts)\")" % iff)


def check_matcher_group(findings, group, ptr):
    if not isinstance(group, dict):
        add(findings, ptr, "error",
            "matcher group must be an object, got %s" % type(group).__name__)
        return
    if "matcher" in group and not isinstance(group["matcher"], str):
        if isinstance(group["matcher"], list):
            add(findings, ptr + "/matcher", "error",
                "'matcher' must be a STRING (use \"Edit|Write\"), not an array "
                "— an array is a schema error and the hook is silently dropped")
        else:
            add(findings, ptr + "/matcher", "error",
                "'matcher' must be a string, got %s"
                % type(group["matcher"]).__name__)
    hooks = group.get("hooks")
    if hooks is None:
        add(findings, ptr, "error", "matcher group missing 'hooks' list")
    elif not isinstance(hooks, list):
        add(findings, ptr + "/hooks", "error",
            "'hooks' must be a list, got %s" % type(hooks).__name__)
    else:
        for i, entry in enumerate(hooks):
            check_hook_entry(findings, entry, "%s/hooks/%d" % (ptr, i))


def lint(doc):
    """Return list[Finding] for a parsed hooks.json / settings.json document."""
    findings = []
    if not isinstance(doc, dict):
        add(findings, "", "error",
            "top-level value must be an object "
            '({"hooks": {...}} or a bare event map)')
        return findings

    # Accept either {"hooks": {<Event>: [...]}} or a bare event map.
    if "hooks" in doc and isinstance(doc["hooks"], dict):
        events = doc["hooks"]
        base = "/hooks"
    else:
        # Bare event map only if keys look like events; otherwise flag shape.
        keys = list(doc.keys())
        if keys and any(k in KNOWN_EVENTS for k in keys):
            events = doc
            base = ""
        else:
            add(findings, "", "error",
                'expected {"hooks": {<Event>: [...]}} or a bare event map; '
                "found object with keys: %s" % ", ".join(keys) or "(empty)")
            return findings

    for event, groups in events.items():
        eptr = "%s/%s" % (base, event)
        if event not in KNOWN_EVENTS:
            add(findings, eptr, "error",
                "unknown hook event %r — not in the 30-event catalog "
                "(see references/hooks-reference.md)" % event)
            # still structurally validate its groups below
        if not isinstance(groups, list):
            add(findings, eptr, "error",
                "event value must be a list of matcher groups, got %s"
                % type(groups).__name__)
            continue
        for i, group in enumerate(groups):
            check_matcher_group(findings, group, "%s/%d" % (eptr, i))
    return findings


def default_path():
    """Repo's hooks/hooks.json: try cwd, then git toplevel."""
    cand = os.path.join(os.getcwd(), "hooks", "hooks.json")
    if os.path.isfile(cand):
        return cand
    try:
        top = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5)
        if top.returncode == 0:
            cand = os.path.join(top.stdout.strip(), "hooks", "hooks.json")
            if os.path.isfile(cand):
                return cand
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def main(argv):
    p = argparse.ArgumentParser(
        prog="validate-hooks-json.py",
        description="Lint a hooks.json / settings.json hooks block against "
                    "the Claude Code hook contract (offline, structural).",
        epilog="EXAMPLES:\n"
               "  validate-hooks-json.py hooks/hooks.json\n"
               "  validate-hooks-json.py --json .claude/settings.json | jq '.data[]'\n"
               "  validate-hooks-json.py --strict ./hooks.json\n"
               "\nEXIT: 0 clean, 2 usage, 3 not-found, 4 malformed-JSON, "
               "10 findings present.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("path", nargs="?",
                   help="hooks.json or settings.json (default: repo hooks/hooks.json)")
    p.add_argument("--json", action="store_true",
                   help="emit a JSON envelope (schema %s)" % SCHEMA)
    p.add_argument("--strict", action="store_true",
                   help="count warnings toward the exit-10 signal")
    try:
        args = p.parse_args(argv)
    except SystemExit as e:
        # argparse exits 0 for --help (good), 2 for bad args (matches USAGE).
        return e.code if e.code is not None else EXIT_USAGE

    path = args.path or default_path()
    if not path:
        msg = ("no path given and no repo hooks/hooks.json found "
               "(pass a path explicitly)")
        if args.json:
            print(json.dumps({"error": {"code": "NOT_FOUND", "message": msg}}))
        print("ERROR: %s" % msg, file=sys.stderr)
        return EXIT_NOT_FOUND

    if not os.path.isfile(path):
        msg = "file not found: %s" % path
        if args.json:
            print(json.dumps({"error": {"code": "NOT_FOUND", "message": msg}}))
        print("ERROR: %s" % msg, file=sys.stderr)
        return EXIT_NOT_FOUND

    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        msg = "malformed JSON in %s: %s" % (path, e)
        if args.json:
            print(json.dumps({"error": {"code": "VALIDATION", "message": msg}}))
        print("ERROR: %s" % msg, file=sys.stderr)
        return EXIT_MALFORMED

    print(TERM.hdr("hooks-lint: %s" % path), file=sys.stderr)
    findings = lint(doc)

    errors = [f for f in findings if f.severity == "error"]
    warnings = [f for f in findings if f.severity == "warning"]

    if args.json:
        print(json.dumps({
            "data": [f.as_dict() for f in findings],
            "meta": {"count": len(findings),
                     "errors": len(errors), "warnings": len(warnings),
                     "path": path, "schema": SCHEMA},
        }, indent=2))
    else:
        for f in findings:
            print("%s\t%s\t%s" % (f.severity, f.pointer or "/", f.message))

    # Human framing → stderr.
    for f in findings:
        if f.severity == "error":
            mk, tag = TERM.mark("bad"), TERM.c("red", "ERROR")
        else:
            mk, tag = TERM.mark("warn"), TERM.c("orange", "warn")
        print("  %s %s %s: %s" % (mk, tag, f.pointer or "/", f.message),
              file=sys.stderr)
    if not findings:
        print("  %s clean, no findings" % TERM.mark("ok"), file=sys.stderr)
    print("--- %s error(s), %s warning(s) ---"
          % (TERM.c("red", str(len(errors))), TERM.c("orange", str(len(warnings)))),
          file=sys.stderr)

    if errors or (args.strict and warnings):
        return EXIT_FINDINGS
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
