---
adr_id: ADR-0004
title: Phase Pipeline for /meta-harness:improve (tighten → lateral → sharpen → deterministic)
status: Accepted
date: "2026-05-28"
related_requirements: [FR-3, NFR-1, NFR-4, NFR-5, HR-1, HR-5, AC-3]
supersedes_partial: [ADR-0003 §Future Work (improve-loop diversification)]
---

# ADR-0004: Phase Pipeline for `/meta-harness:improve`

## Context

v2.0 shipped `/meta-harness:improve` as a single deterministic loop:
**evaluate → pick top finding → propose patch → apply → re-evaluate**,
capped at 3 rounds. That loop is good at one thing — closing
**coverage gaps and stale references** by adding stubs or deleting
files — and it is reproducible because every step except evaluation
itself is deterministic.

But fit-improvement in practice has multiple distinct failure modes,
and the v2.0 loop only addresses one of them:

| Failure mode                                                                                  | v2.0 loop's response |
|------------------------------------------------------------------------------------------------|----------------------|
| Missing skill / agent for a real workflow (coverage-gap)                                       | Adds a stub          |
| Harness references a path the project no longer has (stale-reference)                          | Deletes the line     |
| Harness has a skill the project never uses (over-coverage)                                     | Moves file to snapshot |
| **SKILL.md body bloated with restated principles / explanations Claude doesn't need**          | **Does nothing**     |
| **SKILL.md body has a 200-line API table inline when it could be in `references/`**            | **Does nothing**     |
| **YAML `description` is generic ("This skill helps with X") and undertriggers**                | **Does nothing**     |

The last three failure modes are well-documented in current Claude
Code / agent-skills guidance:

- **Karpathy's Goldilocks U-curve.** Treating context as RAM means
  *too little* (Claude lacks orientation) and *too much* (Claude can't
  find the signal) both degrade behavior. The "nanoGPT no monsters"
  aesthetic — small, sharp, readable — applies to harness instructions
  too.
- **Anthropic's conciseness test** ([Claude Code best practices](https://code.claude.com/docs/en/best-practices)):
  *"For each line, ask: 'Would removing this cause Claude to make
  mistakes?' If not, cut it."* Real agent-skills tend to cluster at
  150-400 lines; 500 is the structural cap.
- **Anthropic's progressive disclosure pattern** ([Agent Skills blog](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)):
  L1 (frontmatter) is always loaded, L2 (SKILL.md body) is loaded on
  every activation, L3 (`references/<topic>.md`) is loaded only when
  navigated. Heavy reference material in L2 is a recurring token cost
  that should be in L3.
- **Anthropic's skill-creator note:** Claude tends to *undertrigger*
  skills; the YAML `description` is the highest-leverage field — it's
  the entire signal the runtime uses to decide whether the skill is
  relevant. Anthropic explicitly recommends a slightly pushy
  "use when …" phrasing with concrete trigger phrases.
- **Hamel Husain's evals-first principle**
  ([source](https://hamel.dev/blog/posts/evals-faq/should-i-stop-writing-prompts-manually-in-favor-of-automated-tools.html)):
  *"If you delegate this task to an automated tool too early, you risk
  never fully understanding your own requirements or the model's
  failure modes."* This warns directly against letting an LLM
  free-form-rewrite a skill body without an eval to score the result.

So the question is: how do we extend improve to address shape and
sharpness, without violating Hamel's warning?

## Options Considered

### Option A — Free-form LLM body rewriting (REJECTED)

Have improve invoke an LLM to rewrite SKILL.md bodies for "clarity" or
"richness" in a single uncons­trained pass.

- Pros: would cover the most failure modes in the fewest passes.
- Cons:
  - Directly violates Hamel's warning — no eval gate, no human
    in-the-loop on the rewrite, and the analyzer's `actionable` count
    is not a sufficient proxy for "the rewrite is good".
  - Diff is enormous; per-line approval becomes meaningless.
  - The deletion-only invariant (rollback cleanly to a strict subset
    of the prior file) is lost — any error makes the rewrite hard to
    undo.

### Option B — Separate skill per phase (REJECTED, user feedback)

Initial sketch: `harness-tighten`, `harness-lateral`, `harness-sharpen`
as standalone skills with their own slash commands, plus a
`harness-orchestrate` shell that chains them.

- Pros: each phase is a discrete unit with its own SKILL.md.
- Cons:
  - 4 new skill directories + 3 new top-level commands for what is
    architecturally one workflow.
  - Cross-skill state coordination (snapshots, round-state JSON) gets
    awkward across separate skill files.
  - User feedback: *"스킬 구조가 고민되네. 좀 복잡해보이는데.."* (the
    skill structure is getting complicated).
  - Discoverability worsens — `/meta-harness:improve` no longer is the
    canonical "improve the harness" verb.

### Option C — Extend `harness-improve` with an in-skill phase pipeline (CHOSEN)

One skill, one command, four phases inside the skill's procedural
spine. The phases are:

1. **tighten** (LLM, deletion-only)
2. **lateral** (LLM, structural extraction to `references/<topic>.md`)
3. **sharpen** (LLM, YAML-frontmatter-only)
4. **deterministic** (no LLM, the v2.0 catalog)

`--phases <csv>` selects a subset; the default is all four.
`--phases deterministic` runs ONLY phase 4 and preserves the v2.0
behavior byte-for-byte (the AC-3 reproducibility anchor).

- Pros:
  - Each phase has a **narrow, eval-gated invariant** that addresses
    Hamel's warning — see the Decision section below.
  - One skill, one command — no new top-level surface area.
  - Subsetting via `--phases` lets callers compose the workflow
    without code changes (CI pins `--phases deterministic`; daily
    interactive use takes the default).
  - Existing v2.0 state file schema extends naturally (one new `phase`
    field per round).
- Cons:
  - Single SKILL.md grows from ~500 to ~900 lines. Mitigation: each
    phase has a clearly-delimited section; the spine of the skill
    remains the per-round procedure.
  - Per-phase regression guards add evaluate calls (cost; each phase
    invokes evaluate at least once for `before_fit` + `after_fit`).
    Mitigation: phases 2-4 reuse the prior phase's `after_fit` as
    their `before_fit`.

### Option D — Status quo (REJECTED)

Leave improve as the v2.0 deterministic loop. Tighten / lateral /
sharpen are operator-driven manual edits.

- Pros: zero implementation work; AC-3 trivially preserved.
- Cons: the three high-leverage failure modes above stay
  permanently unaddressed by the plugin. Users who don't already know
  the Anthropic guidance won't apply it on their own.

## Decision

**Option C is adopted.** The four-phase pipeline is the new improve
default; `--phases deterministic` is the v2.0 reproducibility escape
hatch.

### Phase invariants (Hamel-compliant constraints)

Each LLM phase is bound by a structural invariant that makes the LLM's
output reviewable, reversible, and bounded. The invariants are what
distinguish this design from the Option A free-form rewrite Hamel warns
against.

| Phase | LLM mutation surface                        | Structural invariant                                                                                              | Eval gate |
|-------|---------------------------------------------|-------------------------------------------------------------------------------------------------------------------|-----------|
| 1. tighten | Set of line ranges to DELETE          | **Deletion-only.** Post-apply content must be a strict line subset of the snapshot. Verified by hash comparison.   | post-phase evaluate; revert on `delta_actionable > 0` |
| 2. lateral | `{source_range, target_file, pointer_line}` triples | Source ranges non-overlapping; target_file under same skill dir; pointer_line is a valid markdown link; source_range ≥ 30 lines (no thrash). | same      |
| 3. sharpen | YAML `description` / `when_to_use` strings | **Body-untouched.** Body hash before/after must match. `description` + `when_to_use` ≤ 1,500 chars (Anthropic 1,536 cap minus 36-char buffer). | same      |
| 4. deterministic | Predetermined patch from finding category | No LLM; mapping is a finite enumeration (stub / line-delete / file-delete). | per-round before/after evaluate |

The deletion-only invariant on phase 1, the body-untouched invariant
on phase 3, and the structural validators on phase 2 are what make the
LLM phases reversible and reviewable. Each phase's "free parameter
space" is small enough that the unified diff is human-reviewable.

### Phase ordering — subtract before add

The canonical phase order is **`tighten → lateral → sharpen →
deterministic`**, and the ordering is load-bearing:

1. **tighten first.** Deletion cannot worsen what comes after — every
   subsequent phase operates on a file that is at-most-as-long-as the
   input. If we ran tighten after sharpen, the LLM-rewritten
   description would be reviewed against a body that still contains
   bloat the operator was about to delete; the description rewrite
   would target the wrong body shape.
2. **lateral second.** Restructuring should happen on the
   already-tightened body. If we ran lateral before tighten, we'd
   extract sections that themselves contain redundancy; the
   extracted `references/<topic>.md` would inherit bloat.
3. **sharpen third.** The YAML `description` should describe the
   final (post-tighten, post-lateral) skill, not the original. Running
   sharpen first means the description targets a body that no longer
   exists by the end of the pipeline.
4. **deterministic last.** Adding missing coverage should happen
   against the now-tightened body — the new stub slots into a shape
   where the conciseness test has already been applied. If we ran
   deterministic first, tighten would then have to delete from a body
   that just got new content, and the LLM might mistake newly-added
   stub language for bloat.

This is the "subtract before add" principle. Reordering would
re-introduce the failure modes Karpathy's U-curve and Anthropic's
conciseness test warn against.

### Per-phase regression guards

Phases 1-3 each run an evaluate **after** apply. If the analyzer's
`actionable` count rises (the phase made the harness worse by some
measurable proxy), the phase is **auto-reverted from snapshot** and
recorded as `regressed: true`. The pipeline does NOT terminate on
regression — it advances to the next phase, because phase regressions
are non-fatal (a no-op tighten doesn't preclude a useful sharpen).

This is the Hamel eval gate in concrete form: the LLM proposed, the
analyzer judged, and the snapshot is the rollback substrate. The
operator's manual review at the approval gate is the *second*
defense; the analyzer's regression detection is the *first*.

### AC-3 anchored to phase 4

The AC-3 reproducibility contract (3-round cap, `"max 3 rounds
reached"` literal, state file length 3) is preserved exactly by
`--phases deterministic`. The LLM phases are not bit-reproducible by
design; AC-3 cannot bind them. CI gates, golden-file tests, and any
caller depending on byte-stable output MUST pin
`--phases deterministic`.

The state file schema_version bumps **1 → 2** in v2.1: each round
gains a `phase` field; `meta` gains `phases_requested` /
`phases_executed`. The AC-3 verification check adds a fourth jq
clause: `all(.rounds[]; .phase == "deterministic")`.

### Per-phase + outer approval gates

Approval gates compound:

1. **Outer cwd prompt.** HR-3 gate, fired once at the top of the run.
   `--auto` does NOT skip it. Same as v2.0.
2. **Per-phase approval prompt.** Each phase shows its aggregated diff
   and asks `Apply this proposal? [y/N]`. `--auto` skips. Default N.
3. **Per-round approval prompt (phase 4 only).** Inside the
   deterministic loop, every round's single-finding patch gets its own
   approval prompt. Same as v2.0.

A decline at any per-phase or per-round prompt sets
`exit_reason: user_declined` and **skips all subsequent phases**.
The user opted out of the pipeline at that point; subsequent LLM
calls would be wasted spend.

## Consequences

### Positive

- The three previously-unaddressed failure modes (body bloat, heavy
  inline references, generic descriptions) now have first-class
  workflows backed by current Anthropic / Karpathy / Hamel guidance.
- One skill, one command — no new surface area. Discoverability
  preserved.
- AC-3 is unaffected for callers that pin `--phases deterministic`.
- Each LLM phase's structural invariant makes its diff small and
  reviewable; the regression guard adds an automated eval gate on
  top of the operator's manual review.
- Composability via `--phases <csv>` — operators choose
  subtract-only (`--phases tighten,lateral`), description-only
  (`--phases sharpen`), or any subset, without new commands.

### Negative

- `skills/harness-improve/SKILL.md` grows from ~500 to ~900 lines.
  Mitigation: each phase is its own clearly-delimited section;
  the per-round procedure spine is untouched from v2.0.
- LLM phases add cost — each phase invokes evaluate at least twice
  (before_fit + after_fit), plus the LLM proposer call. Mitigation:
  phases 2-4 reuse the prior phase's `after_fit` as their
  `before_fit`; LLM calls are token-bounded by the per-phase
  validators.
- LLM phases are not bit-reproducible. Mitigation: AC-3 is scoped to
  `--phases deterministic`; the README and command help direct
  CI / golden-test callers to that flag.
- Pipeline runtime grows from ~3 evaluate calls (v2.0) to ~7-9 in
  the full default run. Mitigation: `--phases deterministic`
  remains a 1-call-per-round path for time-sensitive use.
- The per-phase regression guard fires evaluate twice in the
  "regressed" case (before, then after the auto-revert is implied —
  but we don't actually re-evaluate after the revert because the
  state is the pre-apply snapshot which already has `before_fit`
  measured). Recorded honestly as `regressed: true` with the
  measured delta.

### Neutral

- Future eval-gated body rewriting (Option A done right) is left
  open: a phase 5 could be added when there's an evaluator that can
  score "is this rewrite good" beyond `actionable` count. Until then,
  free-form body rewriting stays out of scope (see SKILL.md §Out of
  scope for v2.1).
- Token-budget enforcement (a "this skill must be ≤ N tokens" gate)
  is not implemented in v2.1; phases 1-2 surface bloat to the
  operator via diff, but no hard cap is enforced. Considered for
  future phases.

## Future Work (v2.x candidates)

- **Phase 5: eval-gated body refresh.** Once meta-harness has a
  harness-quality eval beyond `actionable` count (e.g., LLM-as-judge
  scoring rubric over a held-out set of project prompts), Option A
  becomes safe — the eval gates the rewrite and Hamel's warning is
  satisfied.
- **Multi-finding rounds in phase 4.** Address several findings per
  deterministic round. Complicates rollback (currently one snapshot
  per round = one finding) but reduces total round count.
- **Phase-specific `--max-rounds`.** Currently `--max-rounds` only
  caps phase 4; phases 1-3 are single-pass. A phase-1-multi-pass
  (delete, re-evaluate, delete more) might be useful but introduces
  the same diminishing-returns problem the v2.0 cap exists to
  prevent.
- **Token-budget enforcement.** A hard cap like
  `--max-tokens-per-skill 8000` that auto-extracts any over-budget
  SKILL.md to references — could be implemented as a stricter
  phase 2 variant.
- **`.muted_findings` for declined proposals.** Cross-run memory so
  the same proposal isn't re-offered after the operator declined it.
  Also relevant to phase 4.
- **Diff-aware skipping.** If `--phases tighten` has already run in a
  prior session and no relevant files changed, the LLM call could be
  skipped. Requires a per-phase fingerprint in the state file.
