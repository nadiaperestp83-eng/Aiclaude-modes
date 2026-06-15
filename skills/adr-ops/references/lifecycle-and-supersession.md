# ADR Lifecycle and Supersession

ADRs are **append-only project memory**. Once a record is `accepted`, its Decision and
Context are not rewritten to reflect a new reality — that erases the record. Change comes
through supersession, addenda, or narrow in-place fixes, never by editing the decision.

---

## Status lifecycle

```
proposed  ──►  accepted  ──►  superseded   (superseded-by: [ADR-NNN])
                  │
                  └─────────►  deprecated   (withdrawn; nothing replaces it)
```

| `status` | Meaning |
|---|---|
| `proposed` | Drafted, under discussion, not yet in force. Rare — most ADRs land accepted. |
| `accepted` | In force. The default landing state. |
| `superseded` | Replaced by a newer decision; `superseded-by` names it. The record stays. |
| `deprecated` | The decision no longer applies and nothing replaces it. |

---

## The three change modes

When something about a decision needs to change, pick exactly one mode.

### 1. Supersede — the decision itself changes

A new decision replaces an old one. This is a **record, not a deletion** — `git log`
should never be the only place a reversal lives.

1. Write a **new** ADR with the next number. Set its frontmatter `supersedes: [ADR-OLD]`.
2. In the old ADR, edit **frontmatter only**: set `status: superseded` and
   `superseded-by: [ADR-NEW]`. Leave its body intact — the obsolete reasoning is itself
   a record of how thinking changed.
3. Do both in the **same commit**.

Supersession is **bidirectional** and `adr-lint.py` enforces it: if A lists
`supersedes: [B]`, then B must have `superseded-by: [A]` AND `status: superseded`, and
vice versa. A one-sided link is a lint error. `adr-new.sh --supersedes ADR-OLD
--apply-supersede` performs the flip for you.

### 2. Addendum — new facts, same decision

A dated `## Addendum — YYYY-MM-DD: <topic>` section at the **end** of the body is for new
facts that *refine* an in-force decision (an implementation note, a discovered
constraint). It does not change the decision. Do **not** use an addendum to quietly
reverse the decision — that is a supersession.

### 3. In-place edit — typos, dead links, renamed paths

In-place edits for typos, broken links, or a renamed path in `touches:` are fine — they
preserve the record's meaning. Use judgement: correcting a path is maintenance; rewriting
the rationale is not. Normalising format across the whole corpus is maintenance — it
changes presentation, not decisions.

---

## Decision tree

```
Does the standing rule change?
├── YES → Supersede (new ADR + flip the old record's frontmatter, same commit)
└── NO
    ├── New fact refining the decision?     → Addendum (dated section at the end)
    └── Typo / dead link / renamed path?    → In-place edit (frontmatter or body)
```

> Rule of thumb for whether it is even an ADR at all: if someone could plausibly undo
> the change next month without re-litigating a trade-off, it is not an ADR — it is a
> commit message or a code comment.
