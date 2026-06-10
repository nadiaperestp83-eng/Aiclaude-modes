# Agents Catalog

Complete reference for all available agents in the Task tool.

**Note:** Language and framework domains (Python, JavaScript, TypeScript, Go, Rust, React, Vue, Laravel, Astro, SQL, PostgreSQL) are covered by `-ops` skills, not agents — see `skills-catalog.md`. When subagent work is needed in those domains, dispatch `general-purpose` with an instruction to first read the relevant skill's SKILL.md and references (skill preloading).

## Language Experts

### bash-expert

**Triggers:** bash, shell, script, zsh, cli

**Capabilities:**
- Defensive bash scripting
- Error handling and traps
- CI/CD pipeline scripts
- System utilities
- Cross-platform considerations

**Best For:**
- Production automation scripts
- CI/CD pipelines
- System administration
- Build scripts

---

## Infrastructure Experts

### cloudflare-expert

**Triggers:** cloudflare, workers, pages, kv, d1, r2

**Capabilities:**
- Workers development
- KV/D1/R2 storage
- Edge computing patterns
- Security configuration
- DNS and CDN setup

**Best For:**
- Cloudflare Workers apps
- Edge optimization
- Storage architecture
- Security hardening

---

### wrangler-expert

**Triggers:** wrangler, deploy, cloudflare cli

**Capabilities:**
- Wrangler CLI configuration
- Multi-environment deployment
- Binding configuration
- Troubleshooting deployments
- CI/CD integration

**Best For:**
- Deployment issues
- Wrangler configuration
- Environment setup
- CI/CD pipelines

---

### aws-fargate-ecs-expert

**Triggers:** ecs, fargate, aws containers, task definition

**Capabilities:**
- ECS/Fargate deployment
- Task definitions
- Service Auto Scaling
- Networking (awsvpc)
- Logging (FireLens)

**Best For:**
- Container deployment on AWS
- ECS architecture
- Scaling strategy
- Cost optimization

---

## Specialized Experts

### firecrawl-expert

**Triggers:** firecrawl, web scraping, crawl, anti-bot

**Capabilities:**
- Web scraping strategies
- Anti-bot bypass
- Dynamic content handling
- Structured data extraction
- API integration

**Best For:**
- Complex scraping tasks
- Blocked site access
- Data extraction pipelines
- Crawl architecture

---

### payloadcms-expert

**Triggers:** payload, payload cms, headless cms

**Capabilities:**
- Payload CMS architecture
- Collection configuration
- Access control design
- Media handling
- Multi-tenant setup

**Best For:**
- Payload project setup
- Access control design
- Schema planning
- Integration patterns

---

### craftcms-expert

**Triggers:** craft, craftcms, twig

**Capabilities:**
- Craft CMS development
- Twig templates
- Plugin development
- Matrix fields
- GraphQL API

**Best For:**
- Craft CMS projects
- Template development
- Custom field types
- Content modeling

---

### cypress-expert

**Triggers:** cypress, e2e, component testing, test runner

**Capabilities:**
- E2E test architecture
- Component testing
- Custom commands
- Network stubbing
- CI integration

**Best For:**
- E2E test suite setup
- Test architecture
- Flaky test debugging
- CI optimization

---

### asus-router-expert

**Triggers:** asus router, asuswrt, merlin, network hardening

**Capabilities:**
- Asus router configuration
- Asuswrt-Merlin firmware
- Network hardening
- VPN and firewall setup

**Best For:**
- Router configuration
- Home network security
- Firmware feature guidance

---

### claude-architect

**Triggers:** claude code extensions, skills, agents, hooks, MCP, plugins

**Capabilities:**
- Skill/agent/command/hook design
- Plugin and marketplace configuration
- MCP server integration
- Extension debugging

**Best For:**
- Building Claude Code extensions
- Reviewing skills and agents
- Plugin architecture decisions

---

### git-agent

**Triggers:** commit, push, PR, branch, rebase (dispatched by git-ops)

**Capabilities:**
- Background git write operations
- Commit and PR creation
- Branch and worktree management
- Safety-tiered execution

**Best For:**
- Dispatched git work from the git-ops skill
- Background commits and pushes

---

### project-organizer

**Triggers:** restructure, organize, cleanup, directory

**Capabilities:**
- Project structure analysis
- Directory reorganization
- Old file cleanup
- Git-aware operations
- Best practice structure

**Best For:**
- Project restructuring
- Codebase cleanup
- Structure standardization
- Tech debt reduction

---

## Built-in Agents

### Explore

**Triggers:** where is, find, locate, codebase search

**Capabilities:**
- Fast codebase exploration
- Pattern matching
- File discovery
- Quick answers

**Best For:**
- "Where is X defined?"
- "Find files matching Y"
- Quick codebase questions

---

### Plan

**Triggers:** plan, design, architect, strategy

**Capabilities:**
- Implementation planning
- Architecture design
- File identification
- Trade-off analysis

**Best For:**
- Feature planning
- Architectural decisions
- Implementation strategy

---

### general-purpose

**Triggers:** multi-step, complex, research

**Capabilities:**
- Autonomous research
- Multi-step tasks
- Code search
- Tool coordination

**Best For:**
- Complex investigations
- Open-ended research
- Multi-step operations

---

### claude-code-guide

**Triggers:** how to use claude code, can claude code, does claude code

**Capabilities:**
- Claude Code documentation
- Feature explanations
- Hook configuration
- MCP server setup
- Agent SDK guidance

**Best For:**
- Claude Code questions
- Configuration help
- Feature discovery
- SDK usage

---

## Selection Guide

| Need | First Try | Then Try |
|------|-----------|----------|
| "How to write X in Python" | python-* skill (e.g. python-pytest-ops) | general-purpose + skill preload |
| "Optimize this query" | postgres-ops skill | general-purpose + skill preload |
| "Find where X is defined" | Explore | general-purpose |
| "Plan feature implementation" | Plan | general-purpose |
| "Scrape this website" | firecrawl-expert | - |
| "Deploy to Cloudflare" | wrangler-expert | cloudflare-expert |
| "Fix React performance" | react-ops skill | general-purpose + skill preload |
| "Write E2E tests" | cypress-expert | - |
| "Restructure project" | project-organizer | - |
| "Go concurrency design" | go-ops skill | general-purpose + skill preload |
| "Rust lifetime issues" | rust-ops skill | general-purpose + skill preload |
| "Build a Claude Code skill" | claude-architect | - |
