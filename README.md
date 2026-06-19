 ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗    ███╗   ███╗ ██████╗ ██████╗ ███████╗
██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝    ████╗ ████║██╔═══██╗██╔══██╗██╔════╝
██║     ██║     ███████║██║   ██║██║  ██║█████╗      ██╔████╔██║██║   ██║██║  ██║███████╗
██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝      ██║╚██╔╝██║██║   ██║██║  ██║╚════██║
╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗    ██║ ╚═╝ ██║╚██████╔╝██████╔╝███████║
 ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝    ╚═╝     ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝

[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-blueviolet?logo=anthropic)](https://docs.anthropic.com/en/docs/claude-code)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> *A comprehensive extension toolkit that transforms Claude Code into a specialized development powerhouse.*

**claude-mods** is a production-ready plugin that extends Claude Code with 91 specialized skills, 3 expert agents, 13 output styles, 11 hooks, and modern CLI tools designed for real-world development workflows. Whether you're debugging React hooks, optimizing PostgreSQL queries, or building production CLI applications, this toolkit equips Claude with the domain expertise and procedural knowledge to work at expert level across multiple technology stacks.

Built on the [Agent Skills specification](https://agentskills.io/specification) (an open standard backed by Anthropic, Vercel, Google, Microsoft, and 40+ agent platforms), claude-mods fills critical gaps in Claude Code's capabilities: persistent session state that survives across machines, on-demand expert knowledge for specialized domains, token-efficient modern CLI tools (10-100x faster than traditional alternatives), and proven workflow patterns for TDD, code review, and feature development. The toolkit implements Anthropic's [recommended patterns for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), ensuring your development context never vanishes when sessions end.

From Python async patterns to Rust ownership models, from AWS Fargate deployments to Craft CMS development - claude-mods provides the specialized knowledge and tools that transform Claude from a general-purpose assistant into a domain expert who understands your stack, remembers your workflow, and ships production code.

**3 agents. 93 skills. 13 styles. 11 hooks. 8 rules. One install.**

## Recent Updates

**v3.1.0** (June 2026)
- 🗺️ **`mapbox-ops` skill** - advanced Mapbox GL JS for the web (v3): custom SVG/canvas markers and circular photo pins, thematic dataviz (choropleth, heatmaps, proportional symbols, 3D extrusions), terrain with hillshade and contours, cinematic flight/orbit camera and animated day–night cycles, style composition (v3 Standard slots + config, classic palette recolour, third-party styles), expression-driven styling, and the hard-won gotchas that silently drop your markers. 14 reference files plus a headless-Playwright marker-alignment verifier.
- 📐 **Skill Creation Protocol** - [docs/SKILL-CREATION-PROTOCOL.md](docs/SKILL-CREATION-PROTOCOL.md), the canonical "how to build a claude-mods skill" doc: one sequenced lifecycle (warranted? → frontmatter → body → resources → tests → repo wiring → ship) that cites the layer-owning docs rather than restating them, with a precedence table for when they disagree.
- 📋 **`adr-ops` skill** - Architecture Decision Records as a cross-project workflow. ADRs are append-only project memory: they capture *why* a system took its shape — the alternatives weighed, the constraints accepted — so a future maintainer recovers the reasoning without archaeology through git history or chat logs. Brings the when-to-write rule, canonical format, proposed→accepted→superseded lifecycle, and append-only supersession discipline, with five Resource-Protocol tools (init / new / index / `touches`-query / lint) and a 72-assertion suite.
- 📚 **`okf-ops` skill** - assess, validate, and adopt the [Open Knowledge Format](https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing/) — Google Cloud's vendor-neutral spec (v0.1, Apache-2.0) for packaging organizational knowledge as a directory of markdown files with YAML frontmatter that AI agents can query without a platform or SDK. A read-only readiness scanner finds good adoption candidates across many repos; a conformance validator (`--strict` for CI) checks a bundle. Honest scope baked in — OKF is a v0.1 draft, adopt per-repo.
- 📦 **`pypi-ops` skill** - publish Python packages to PyPI the 2026 way: OIDC Trusted Publishing with PEP 740 attestations via `gh-action-pypi-publish`, not stored API tokens. First-publish pending-publisher setup, the `invalid-publisher` / "already exists" failure ladder, TestPyPI dry runs, release-environment approval gates, local `uv publish` / `twine`, and a stale-OIDC-federation audit.
- 🔍 **github-ops auditor family** - a read-only repo-health suite: a security-posture auditor (Dependabot / secret + code scanning / private vuln reporting / SECURITY.md / branch protection, visibility-aware severity), open-issue surfacing wired into the pre-push gate as an advisory, and a scored `repo-scorecard` capstone that grades a repo — or an entire `--org` — in one pass, emitting fix commands but never applying them. The whole family now renders through the `term.sh` panel design system.

[View full changelog →](CHANGELOG.md)

## Why claude-mods?
...
