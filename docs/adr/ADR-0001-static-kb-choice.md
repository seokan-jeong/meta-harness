---
adr_id: ADR-0001
title: Static Curated Knowledge Base for Harness Evaluation
status: Accepted
date: "2026-05-26"
related_requirements: [FR-5, NFR-2, R-2, R-8]
---

# ADR-0001: Static Curated Knowledge Base for Harness Evaluation

## Context

meta-harness's value proposition is "your project harness scored against an explicit rubric drawn from named authorities" (Karpathy on context engineering, Anthropic on agentic loops, the derived 4-bucket model). The credibility of that score depends directly on the **source of the rubric**.

Four sourcing strategies were considered:

1. **Static curated KB** — Curated text files bundled with the plugin, version-managed via SemVer.
2. **Dynamic fetch** — Pull from Karpathy blog / Anthropic docs URLs at runtime, with a cache.
3. **Synthetic / model-generated** — Have the LLM improvise "what Karpathy would score" at every evaluation.
4. **Hybrid** — Static core + optional dynamic boost.

## Options Considered

### Option 1 — Static curated KB (CHOSEN)

The KB lives as markdown files under `docs/theory/` in the plugin. Each file's YAML frontmatter carries `source` (citation), `version` (KB's own SemVer), and `last_synced` (ISO date). The KB version is tracked separately from the plugin SemVer, and `CHANGELOG.md` records KB bumps under a separate `### KB` heading. The evaluator emits `kb_manifest_hash` so any score is sourceable to a specific KB snapshot.

- **Pros**:
  - Reproducibility ★ — same KB snapshot ⇒ stable scoring (enables NFR-1)
  - Offline operation — no network, no auth
  - Cost-deterministic — no per-evaluation fetch, so token budgets are predictable
  - Auditable change — every KB shift is an explicit CHANGELOG event
- **Cons**:
  - **Ageing** (R-8) — new Karpathy / Anthropic material doesn't reach users until a plugin release
  - **Curator bias** (R-2) — "which principles belong in the KB" is itself a meta-opinion
  - Plugin bundle size growth (NFR-2 budget: ≤500 KB)

### Option 2 — Dynamic fetch

Pull KB text from a pre-defined URL list at evaluation time, cache locally.

- Pros: always current, low curator burden
- Cons:
  - **Reproducibility broken ★** — yesterday's score and today's are not comparable
  - Network dependency + auth (Substack paywalls, Anthropic Confluence, etc.)
  - Fetch failure → fail-closed becomes a frequent workflow stopper
  - Cost: fetch + parse on every run

### Option 3 — Synthetic / model-generated KB

Have the LLM improvise "Karpathy-perspective scoring criteria" inside the evaluation call.

- Pros: zero curation burden
- Cons:
  - **Determinism broken ★★** — LLM emits a different rubric each call; NFR-1 (±1 stability) effectively impossible
  - Epistemic gap between marketing claim ("Karpathy-grade") and actual rubric (the model's training distribution dressed up as Karpathy)
  - Authority of the score is compromised

### Option 4 — Hybrid (static core + optional dynamic boost)

Static KB is the baseline, with an optional dynamic merge.

- Pros: both worlds' advantages
- Cons:
  - Complexity explosion — the reproducibility guard (manifest hash) has to track both channels
  - v1 scope can't simultaneously deliver KB diversity, curation infra, and fetch authentication

## Decision

**Option 1 (Static curated KB) is adopted.**

v1 ships with three KB files:

- `docs/theory/karpathy-context-engineering.md` — distilled context-engineering principles (8)
- `docs/theory/anthropic-agentic-loops.md` — agentic-loops patterns (8)
- `docs/theory/harness-4-bucket-principles.md` — the master rubric: 4 axes × 5 criteria = **20 criteria**

Each KB file's YAML frontmatter carries `source` (original URL / citation), `version` (the KB's own SemVer), and `last_synced` (ISO date). Per-file chunked sha256 hashes plus a `combined_hash` are recorded in `docs/kb-manifest.json`. Evaluation result JSON includes `kb_manifest_hash` so any score can be traced back to its KB snapshot.

## Consequences

### Positive

- NFR-1 (reproducibility) achievable — same `kb_manifest_hash` ⇒ same rubric
- Evaluation cost is deterministic — total KB ≤ 500 KB makes NFR-2 token budgets calculable
- Authority is transparent — users can read the KB files directly to verify what they were scored against

### Negative

- KB ageing (R-8) — mitigated by `last_synced` + CHANGELOG `### KB` heading + future-work entry for dynamic fetch in v2
- Curator bias (R-2) — v1 forces ≥3 sources and mandatory KB citation in rationales, so the principles driving any score are visible. v2 will broaden KB diversity (other researchers, other communities)
- If users freely substitute their own KB, the plugin's "Karpathy-grade" claim no longer holds — the README states this explicitly

### Neutral

- v1 axis weighting is uniform (25% each). Per-user weight adjustment is a v2 candidate, paired with the customization question (Open Question OQ-1 in internal planning).

## Future Work (v2 candidates)

- KB diversity: include other practitioners (LangChain, Cursor, OpenAI Cookbook, etc.)
- Opt-in dynamic fetch ("refresh KB" command) with manifest_hash preservation
- Per-user KB weighting (paired with the customization axes Open Question)
- Meta-evaluation: a separate check that the evaluator is actually *applying* the KB principles, not just citing them
