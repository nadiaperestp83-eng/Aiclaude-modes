---
status: accepted
date: YYYY-MM-DD
supersedes: []
superseded-by: []
touches:
  - "path/one.py"
  - "path/two.py"
  - "config.yaml:some.key"
---

# ADR-NNN: Title in Title Case

## Decision (one sentence)

<One present-tense sentence stating the rule. This is the BLUF — it must stand
alone and be greppable. A reader who reads only this line knows what was decided.>

## Context

<The forces in play: what problem, what constraints, what made this a decision
rather than an obvious default. Enough that the decision reads as inevitable given
the context — not a coin flip.>

## Alternatives considered

<Each serious option, and the specific reason it lost. "We didn't consider any" is
a signal the change may not warrant an ADR. Omit this section only for a forced
decision with no real alternative — and say so explicitly if you omit it.>

## Consequences

### Positive
- <What this buys us.>

### Negative
- <The costs and risks we accept.>

### Non-goals
- <What this ADR deliberately does NOT decide or constrain — fences against
  scope-creep readings.>

## See also

- <Links to the enforcing code, tests, related ADRs, audits. An invariant that is
  enforced by a test should link that test — the protocol is the contract is the
  test.>
