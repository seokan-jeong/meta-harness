---
adr_id: ADR-0001
title: Static Curated KB for the Vendored Harness Evaluator
status: Accepted
date: "{{generated_at}}"
deciders: ["meta-harness v0.1.0 (vendored)"]
project: "{{project_name}}"
kb_set_version: "{{kb_set_version}}"
kb_manifest_hash: "{{kb_manifest_hash}}"
related_criteria: [MG-3, MG-4]
supersedes: null
superseded_by: null
---

# ADR-0001: Static Curated KB for the Vendored Harness Evaluator

> This ADR was generated as part of `/meta-harness:build` bootstrapping
> **{{project_name}}**. It explains why your harness ships with a static,
> versioned knowledge base instead of fetching one at evaluation time. The
> upstream `meta-harness` plugin makes the same decision for itself; this
> file records the consequence for *your* project specifically.

## Status

Accepted.

## Context

The `agents/karpathy-evaluator.md` file in this repo scores this harness on
four axes — Persona, Capabilities, Runtime, Meta-Governance — using a rubric.
That rubric is what makes the score meaningful; without a pinned source it
would be a moving target, and "the score went down" would never be
distinguishable from "the rubric got harsher". Because this project consumes
the evaluator as a vendored copy (the agent was written into your repo at
build time, not invoked over a network), the KB it cites must also live next
to it, at a known version.

This decision is therefore answering: where does the rubric text physically
live, and how does it stay in sync with the upstream `meta-harness` project?

## Decision

The harness uses a **static, vendored knowledge base** at KB set
`{{kb_set_version}}`, fingerprinted by `{{kb_manifest_hash}}`. The rubric
files were copied into your project (or are referenced by hash through the
plugin install root) at `/meta-harness:build` time. The KB does not refresh
automatically; refresh is an explicit, user-driven operation — see
**Re-sync mechanism** below.

## Consequences

### Positive
- **Reproducibility.** The same KB hash always produces the same rubric, so
  three consecutive `/meta-harness:evaluate` runs on the same harness should
  agree within ±1 point per axis (the upstream NFR-1 / AC-6 target).
- **Offline operation.** No network call is required to evaluate this
  harness. Your CI / agent loops can score the harness without internet
  access or auth to a third-party source.
- **Auditable rubric.** You can read the rubric directly (in the upstream
  plugin's `docs/theory/harness-4-bucket-principles.md` at the version
  pinned in `kb_set_version`). Nothing about scoring is hidden behind a
  closed system prompt.

### Negative
- **Staleness.** If upstream `meta-harness` ships a new KB version, your
  pinned copy does NOT automatically pick it up. Your score reflects the
  rubric as of `{{generated_at}}` until you re-sync.
- **Curator bias.** The KB reflects whatever sources the upstream plugin's
  curator selected. You are scored against those sources, not a community
  consensus.

### Neutral
- The KB set version is tracked separately from this project's own version.
  Bumping your product version does not bump the KB; bumping the KB is a
  distinct CHANGELOG entry.

## Alternatives Considered

- **Dynamic fetch at evaluation time.** The evaluator would fetch the latest
  KB from a known URL each run. Rejected because it breaks reproducibility,
  introduces a network dependency in the evaluation path, and means a
  yesterday-vs-today score comparison is meaningless.
- **Multi-source ensemble (LLM averages rubrics from several sources).**
  Rejected for v1 because it explodes the rubric provenance surface — a
  single combined hash no longer pins what the score means.

## Re-sync mechanism

The intended way to pull a fresh KB into this project is
`/meta-harness:manage` (slated for the upstream plugin's M4 milestone).
Until that ships, the supported re-sync path is to re-run
`/meta-harness:build` against this directory: the build skill diffs each
file, surfaces conflicts, and prompts for approval before overwriting any
local edits. See `skills/harness-build/SKILL.md` Step 3 for the exact
contract.

## References

- KB-3 criterion **MG-3** — ADRs exist for non-trivial design decisions.
- KB-3 criterion **MG-4** — KB / rubric version is tracked separately and
  visibly. The frontmatter of this file plus `CHANGELOG.md` satisfy MG-4.
- Upstream: `meta-harness` plugin `docs/adr/ADR-0001-static-curated-kb.md`
  (longer, plugin-author audience).
