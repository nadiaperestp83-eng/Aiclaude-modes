# Skill and Agent Updates

**BEFORE creating or updating any skill or agent**, check the official docs:

| Resource | URL |
|----------|-----|
| Skills | https://code.claude.com/docs/en/skills |
| Sub-agents | https://code.claude.com/docs/en/sub-agents |

These APIs change frequently. For detailed reference (frontmatter fields, decision frameworks), see `docs/SKILL-SUBAGENT-REFERENCE.md`.

## Skill resources (scripts / assets / references)

Anything a skill ships beyond `SKILL.md` follows `docs/SKILL-RESOURCE-PROTOCOL.md`:
stream separation (stdout data-only), semantic exit codes, `--help` with EXAMPLES,
the first-comment-block contract, and `--json` envelopes. A skill that encodes
fast-moving external facts (model IDs, API params, action versions) SHOULD ship a
verifier with the `--offline`/`--live` split (§7) so staleness trips a tripwire
instead of rotting silently. `tests/check-resources.sh` runs the offline mode in CI;
the scheduled `freshness.yml` workflow runs the live mode.

## Terminal output

Skills that print to a TTY follow `docs/TERMINAL-DESIGN.md` and source `skills/_lib/term.sh` for glyphs, colors, and layout helpers. Don't roll your own ANSI codes or state icons — `term_init` plus `term_state_icon` / `term_header` / `term_table_row` cover the common cases and keep the toolkit visually coherent.
