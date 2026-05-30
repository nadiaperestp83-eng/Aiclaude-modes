# Issue Operations Reference

Per-operation playbooks for `gh issue` workflows. Every write op that has author voice (`--body` / `--title`) is **preview-gated** per hard rule 8 — quote the draft verbatim in chat, name the send command, wait for explicit user approval, then send.

## Reads (no preview)

```bash
# Single issue with metadata
gh issue view <n> --repo <owner>/<repo>

# Issue + full comment thread (use this when responding — you need the context)
gh issue view <n> --repo <owner>/<repo> --comments

# Raw JSON for fields the default view omits (createdAt, labels, assignees, etc.)
gh api repos/<owner>/<repo>/issues/<n> --jq '{number,title,state,user:.user.login,labels:[.labels[].name],body}'

# List + filter
gh issue list --repo <owner>/<repo> --state open --label bug --limit 20

# Search across repos
gh search issues "is:open label:bug repo:<owner>/<repo>"
```

When reading an issue you intend to respond to, always pull comments too (`--comments`) — replying to the issue body without seeing the discussion is how stale answers happen.

## Triage (mechanical, no preview)

Labels, assignees, milestones carry no author voice — they're metadata. Surface what you're about to do in chat, but no body preview needed.

```bash
# Add labels
gh issue edit <n> --repo <o>/<r> --add-label "bug,needs-repro"

# Remove labels
gh issue edit <n> --repo <o>/<r> --remove-label "needs-triage"

# Assign
gh issue edit <n> --repo <o>/<r> --add-assignee <user>

# Milestone
gh issue edit <n> --repo <o>/<r> --milestone "v2.11.0"
```

If the repo has a label scheme (`bug`/`feat`/`docs`/`question`/`needs-repro`/`good-first-issue` etc.), match it. `gh label list --repo <o>/<r>` to see what exists. Don't invent labels without asking.

## Comment (preview required)

The flow that gets it wrong without discipline. Always:

1. **Compose** the comment as a quoted block in chat (verbatim, not paraphrased).
2. **Name** the exact send command.
3. **Wait** for explicit approval ("send", "ship it", "looks good", or an edit).
4. **Send** only after approval.

### Template for the chat preview

> Drafted comment for issue #<n>:
>
> ```markdown
> <comment body, exactly as it would be sent>
> ```
>
> Command: `gh issue comment <n> --repo <o>/<r> --body "..."`
>
> Send?

### Send

```bash
gh issue comment <n> --repo <o>/<r> --body "$(cat <<'EOF'
<approved body>
EOF
)"
```

Heredoc with single-quoted `'EOF'` so the body is literal (no shell interpolation). Markdown renders on github.com — code fences, links, `@mentions`, `#refs` all work.

### Tone defaults (project maintainer responding to a reporter)

- Lead with thanks and acknowledge what was right about the report.
- If a fix shipped, state the version/PR. Link the release if minor+.
- If the report uncovered related issues, briefly note them — credit goes to the reporter.
- Sign-off via `@mention` if directly thanking. Don't `@mention` everyone in a thread.
- Don't apologise excessively or perform humility. Match the project's existing voice.
- Anti-patterns: marketing fluff, emoji walls, "we'll get right on it" without a concrete plan.

## Create (preview required — title AND body)

A new issue's title shows in lists and notifications; body is the substance. Preview both.

### Chat preview

> Drafted issue for `<o>/<r>`:
>
> **Title:** `<title>`
>
> **Body:**
> ```markdown
> <body>
> ```
>
> **Labels:** bug, needs-repro
> **Assignee:** (none)
>
> Command: `gh issue create --title "..." --body "..." --label "..."`
>
> Send?

### Send

```bash
gh issue create --repo <o>/<r> \
  --title "<approved title>" \
  --body "$(cat <<'EOF'
<approved body>
EOF
)" \
  --label "<labels>" \
  --assignee "<user>"
```

### Bug report template (recommended body shape)

```markdown
## Problem

<one-paragraph what's wrong + observable symptom>

## Repro

1. <step>
2. <step>

## Expected vs actual

- Expected: <…>
- Actual: <…>

## Environment

- Tool / version: <…>
- OS: <…>

## Suggested cause / fix (optional)

<…>
```

## Edit title/body (preview required)

Same preview discipline as create — edits are public. The original is also preserved in the issue's edit history so reviewers can see what changed.

```bash
gh issue edit <n> --repo <o>/<r> \
  --title "<new title>" \
  --body "$(cat <<'EOF'
<new body>
EOF
)"
```

If you're only changing labels/assignees, that's mechanical — preview not required.

## Close / reopen

Plain close — no preview.

```bash
gh issue close <n> --repo <o>/<r>
gh issue reopen <n> --repo <o>/<r>
```

Closing with a reason (`--reason completed|not-planned|duplicate`) — no preview, but state the reason in chat first.

Closing with a parting comment — **preview the comment** (it's a public post), then:

```bash
gh issue comment <n> --repo <o>/<r> --body "..."   # preview-gated
gh issue close <n> --repo <o>/<r>
```

### Closing-comment templates

**Fixed:**
> Fixed in v<X.Y.Z>. <one-sentence summary of the fix>. <PR link if applicable>.

**Won't fix:**
> Closing as <reason — out of scope / duplicate of #N / by design>. Brief why: <…>. Happy to reopen if <condition>.

**Not reproducible:**
> Closing as not reproducible — tried <what>, saw <what>. If you can share <specific thing>, please reopen.

## Common workflows

### Respond to a bug report and fix

```
1. gh issue view <n> --comments            # context
2. Reproduce locally; identify cause
3. Draft fix on branch; PR with "Fixes #<n>" in body
4. After merge, GitHub auto-closes #<n>; post a closing comment
   with version + link (preview-gated)
```

### Triage incoming issues

```
1. gh issue list --label needs-triage      # batch view
2. For each:
   - gh issue view <n> --comments
   - Apply labels: gh issue edit <n> --add-label … --remove-label needs-triage
   - Assign milestone if scoped
   - If duplicate: comment with "Duplicate of #<m>", close with --reason duplicate
   - If needs more info: comment requesting specifics, add label "needs-repro"
```

### Convert a discussion into an actionable issue

```
1. gh issue view <discussion-n> --comments  # distill the actionable scope
2. gh issue create --title "<scoped title>" --body "<distilled scope, link back to #discussion-n>"
3. Optionally close the discussion with a link to the new issue
```

## Anti-patterns

- ❌ Replying to an issue without reading its existing comments.
- ❌ Inventing labels that don't exist in the project's scheme.
- ❌ Closing with `--reason not-planned` without a comment — leaves the reporter guessing.
- ❌ `@mentioning` every previous commenter to "ping" them — they already got notified.
- ❌ Promising a fix or timeline you can't commit to.
- ❌ Sending a comment without showing the draft to the user first (hard rule 8).
