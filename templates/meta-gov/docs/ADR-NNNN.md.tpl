---
adr_id: ADR-NNNN
title: "<title>"
status: Proposed
date: "{{generated_at}}"
deciders: ["<TODO: names>"]
supersedes: null
superseded_by: null
---

# ADR-NNNN: <title>

> Copy this template to a new file named `ADR-<NNNN>-<short-slug>.md` when you
> make a non-trivial design decision. The MG-3 criterion in the 4-bucket rubric
> rewards harnesses with at least one substantive ADR; a stub-only ADR set
> scores low. Fill every section below before merging.

## Status

`Proposed` | `Accepted` | `Deprecated` | `Superseded by ADR-<XXXX>`

(Pick exactly one. Move from Proposed to Accepted in the same PR that lands
the decision; do not leave Proposed ADRs dangling.)

## Context

Describe the forces at play, the constraint that triggered the decision, and
what would happen if you did nothing. 3-8 sentences. Cite requirements or
risks by ID if your project tracks them.

## Decision

State the chosen option in one or two sentences, in the active voice ("We will
adopt X for Y"). Avoid hedging here; the trade-off goes in Consequences.

## Consequences

### Positive
- <expected benefit 1>
- <expected benefit 2>

### Negative
- <known cost or risk 1>
- <known cost or risk 2>

### Neutral
- <change that is neither obviously good nor obviously bad but should be
  recorded for future readers>

## Alternatives Considered

For each rejected option, give one paragraph: what it would have been, and the
specific reason it lost. Decisions whose ADR shows no alternatives are weak
signals; reviewers will assume the author did not look.

- **Alternative A**: <one-paragraph description and rejection reason>
- **Alternative B**: <one-paragraph description and rejection reason>

## References

- <linked requirement, risk, or external doc>
- <previous ADR this builds on, if any>
