# Claude Agent SDK Reference

The Agent SDK is **Claude Code as a library**: the same agent loop, built-in
tools (file ops, bash, search, web), context management, and permission system,
programmable from Python or TypeScript. Verified against
code.claude.com/docs/en/agent-sdk (2026-06).

| | Python | TypeScript |
|---|---|---|
| Package | `claude-agent-sdk` (`pip install claude-agent-sdk`) | `@anthropic-ai/claude-agent-sdk` (`npm install @anthropic-ai/claude-agent-sdk`) |
| Runtime | Python ≥ 3.10 | Node (bundles a native Claude Code binary — no separate install) |
| Entry point | `query(prompt, options=ClaudeAgentOptions(...))` → async iterator | `query({ prompt, options })` → async iterator |
| Option naming | `snake_case` (`allowed_tools`) | `camelCase` (`allowedTools`) |

Auth: `ANTHROPIC_API_KEY`, or third-party providers via env flags
(`CLAUDE_CODE_USE_BEDROCK=1`, `CLAUDE_CODE_USE_VERTEX=1`,
`CLAUDE_CODE_USE_FOUNDRY=1`, `CLAUDE_CODE_USE_ANTHROPIC_AWS=1` +
`ANTHROPIC_AWS_WORKSPACE_ID`). Note: from June 15, 2026, Agent SDK / `claude -p`
usage on subscription plans draws from a separate monthly Agent SDK credit —
production apps should use API keys.

## When SDK vs raw API

| Signal | Choice |
|---|---|
| Agent must read/edit files, run commands, search a codebase | **Agent SDK** — tools are built in, loop is handled |
| CI/CD automation, "fix the failing test", repo-scale refactors | **Agent SDK** |
| You want hooks, permission gating, session resume out of the box | **Agent SDK** |
| Single call: classify/summarize/extract | **Messages API** — SDK is overkill |
| You need exact control of every request (params, caching breakpoints, message shapes) | **Messages API + tool use** |
| Your tools are pure in-process functions, no filesystem | **Messages API + tool runner** is lighter |
| Hosted agent, no infra at all | **Managed Agents** (REST, Anthropic-run sandbox) |

The difference in code:

```python
# Messages API: you implement the loop
response = client.messages.create(...)
while response.stop_reason == "tool_use":
    result = your_tool_executor(...)
    response = client.messages.create(...)

# Agent SDK: the loop, tools, and context management are inside query()
async for message in query(prompt="Fix the bug in auth.py"):
    print(message)
```

## Minimal agents

```python
import asyncio
from claude_agent_sdk import query, ClaudeAgentOptions

async def main():
    async for message in query(
        prompt="Find all TODO comments and create a summary",
        options=ClaudeAgentOptions(allowed_tools=["Read", "Glob", "Grep"]),
    ):
        if hasattr(message, "result"):       # final ResultMessage
            print(message.result)

asyncio.run(main())
```

```typescript
import { query } from "@anthropic-ai/claude-agent-sdk";

for await (const message of query({
  prompt: "Find all TODO comments and create a summary",
  options: { allowedTools: ["Read", "Glob", "Grep"] },
})) {
  if ("result" in message) console.log(message.result);
}
```

The iterator yields typed messages: system messages (`subtype: "init"` carries
`session_id`), assistant/tool activity, and a final result message
(`message.result` / `ResultMessage`).

## ClaudeAgentOptions (key fields)

| Python | TypeScript | Purpose |
|---|---|---|
| `allowed_tools` | `allowedTools` | Pre-approved tools (no permission prompt). Include `"Agent"` to auto-approve subagent spawns |
| `disallowed_tools` | `disallowedTools` | Hard-blocked tools |
| `permission_mode` | `permissionMode` | e.g. `"default"`, `"acceptEdits"`, `"bypassPermissions"`, `"plan"` |
| `system_prompt` | `systemPrompt` | Replace or extend the system prompt |
| `mcp_servers` | `mcpServers` | MCP server map (see below) |
| `hooks` | `hooks` | Lifecycle callbacks (see below) |
| `agents` | `agents` | Named subagent definitions |
| `resume` | `resume` | Session ID to continue with full context |
| `cwd` | `cwd` | Working directory for the agent |
| `model` | `model` | Override model |
| `max_turns` | `maxTurns` | Cap agent-loop iterations |
| `setting_sources` | `settingSources` | Restrict which filesystem config loads (`.claude/`, `~/.claude/`) |
| `plugins` | `plugins` | Programmatic plugin loading |

### Built-in tools

`Read`, `Write`, `Edit`, `Bash`, `Glob`, `Grep`, `WebSearch`, `WebFetch`,
`Monitor` (watch a background process), `AskUserQuestion` (clarifying
questions with options), `Agent` (spawn subagents). A read-only agent is just
`allowed_tools=["Read", "Glob", "Grep"]`.

## Hooks

Callbacks at lifecycle points: `PreToolUse`, `PostToolUse`, `Stop`,
`SessionStart`, `SessionEnd`, `UserPromptSubmit`, and more. Use them to audit,
block, or transform agent behavior.

```python
from claude_agent_sdk import query, ClaudeAgentOptions, HookMatcher
from datetime import datetime

async def log_file_change(input_data, tool_use_id, context):
    path = input_data.get("tool_input", {}).get("file_path", "unknown")
    with open("./audit.log", "a") as f:
        f.write(f"{datetime.now()}: modified {path}\n")
    return {}        # empty dict = allow; hooks can also block/modify

options = ClaudeAgentOptions(
    permission_mode="acceptEdits",
    hooks={"PostToolUse": [HookMatcher(matcher="Edit|Write", hooks=[log_file_change])]},
)
```

```typescript
import { query, HookCallback } from "@anthropic-ai/claude-agent-sdk";
import { appendFile } from "fs/promises";

const logFileChange: HookCallback = async (input) => {
  const filePath = (input as any).tool_input?.file_path ?? "unknown";
  await appendFile("./audit.log", `${new Date().toISOString()}: modified ${filePath}\n`);
  return {};
};

const options = {
  permissionMode: "acceptEdits" as const,
  hooks: { PostToolUse: [{ matcher: "Edit|Write", hooks: [logFileChange] }] },
};
```

`matcher` is a regex over tool names. A `PreToolUse` hook returning a deny
decision blocks the call — this is the programmatic equivalent of a human
approval gate.

## MCP servers

Wire any MCP server (stdio command or remote) into the agent:

```python
options = ClaudeAgentOptions(
    mcp_servers={
        "playwright": {"command": "npx", "args": ["@playwright/mcp@latest"]},
    },
)
```

```typescript
const options = {
  mcpServers: {
    playwright: { command: "npx", args: ["@playwright/mcp@latest"] },
  },
};
```

MCP tools surface as `mcp__<server>__<tool>` — add them to
`allowed_tools` to pre-approve. This is how you give an agent databases,
browsers, and third-party APIs without writing tool plumbing.

## Subagents

```python
from claude_agent_sdk import query, ClaudeAgentOptions, AgentDefinition

options = ClaudeAgentOptions(
    allowed_tools=["Read", "Glob", "Grep", "Agent"],   # Agent tool approves spawns
    agents={
        "code-reviewer": AgentDefinition(
            description="Expert code reviewer for quality and security reviews.",
            prompt="Analyze code quality and suggest improvements.",
            tools=["Read", "Glob", "Grep"],
        ),
    },
)
# prompt: "Use the code-reviewer agent to review this codebase"
```

Messages emitted inside a subagent carry `parent_tool_use_id` so you can
attribute output to the spawning call. Use subagents to isolate context
(reviewer doesn't pollute the main transcript) and to parallelize independent
legs.

## Sessions: resume and fork

Session state is JSONL on your filesystem. Capture the session ID from the
init message, resume later with full context:

```python
from claude_agent_sdk import query, ClaudeAgentOptions, SystemMessage, ResultMessage

session_id = None
async for message in query(prompt="Read the authentication module",
                           options=ClaudeAgentOptions(allowed_tools=["Read", "Glob"])):
    if isinstance(message, SystemMessage) and message.subtype == "init":
        session_id = message.data["session_id"]

async for message in query(prompt="Now find all places that call it",
                           options=ClaudeAgentOptions(resume=session_id)):
    if isinstance(message, ResultMessage):
        print(message.result)
```

```typescript
let sessionId: string | undefined;
for await (const message of query({ prompt: "Read the authentication module",
                                    options: { allowedTools: ["Read", "Glob"] } })) {
  if (message.type === "system" && message.subtype === "init") {
    sessionId = message.session_id;
  }
}
for await (const message of query({ prompt: "Now find all places that call it",
                                    options: { resume: sessionId } })) {
  if ("result" in message) console.log(message.result);
}
```

Sessions can also be forked to explore alternative approaches from the same
context point.

## Filesystem configuration

With default options the SDK loads Claude Code's filesystem config from
`.claude/` (project) and `~/.claude/` (user): skills
(`.claude/skills/*/SKILL.md`), commands, `CLAUDE.md` memory, plugins. Restrict
with `setting_sources` / `settingSources` when you want a hermetic agent (CI)
that ignores developer-machine state.

## Production patterns

- **CI agent:** `permission_mode="bypassPermissions"` (or a tight
  `allowed_tools` list) + `max_turns` cap + hooks for audit logging. Never
  bypass permissions on a machine with credentials you don't want the agent
  exercising.
- **Approval gate:** `PreToolUse` hook on `Bash|Write|Edit` that checks the
  input and returns deny for out-of-policy actions.
- **Observability:** log every message from the iterator; hook
  `PostToolUse` for tool-level metrics; final `ResultMessage` includes
  cost/usage data.
- **Prototype → production:** a common path is Agent SDK locally (works on
  your filesystem), then Managed Agents for hosted production (Anthropic runs
  the sandbox; custom tools become event round-trips).
- Workflows translate 1:1 with the Claude Code CLI (`claude -p`) — anything
  you can do interactively you can automate via the SDK.
