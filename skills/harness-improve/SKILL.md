---
skill_id: harness-improve
name: Harness Improve Workflow
description: "Procedural workflow for /meta-harness:improve. Runs a 4-phase pipeline against the target harness: (1) tighten — LLM proposes line-deletions per Anthropic's conciseness test; (2) lateral — LLM proposes moving heavy sections to references/; (3) sharpen — LLM rewrites YAML descriptions for triggering; (4) deterministic — the v2.0 3-round (evaluate → pick → propose → approve → apply → re-evaluate) loop. Each phase has its own approval gate. --phases selects a subset; --phases deterministic preserves the v2.0 contract (AC-3 reproducibility)."
invoked_by:
  - commands/improve.md
invokes:
  - skills/harness-evaluate (per-round before/after fit assessment in phase 4 + per-phase delta checks in phases 1-3)
related_requirements: [FR-3, NFR-1, NFR-4, NFR-5, HR-1, HR-3, HR-4, HR-5, AC-3]
related_adrs: [ADR-0003, ADR-0004, ADR-0006]
user-invocable: false
---

# Harness Improve — workflow skill

This skill is the **single source of truth** for the `/meta-harness:improve`
procedure. The slash command (`commands/improve.md`) is a thin trigger;
this file owns the phase pipeline, the per-phase state machine, the
termination logic, and the round-state record format.

Improve is the only verb in v2 that **modifies the target harness on
disk** beyond first-time build. It does so under four guards:

1. **Per-phase user approval** before any apply (NFR-4). Each phase
   renders a diff and prompts `Apply this proposal? [y/N]`. `--auto`
   skips per-phase prompts but not the outer cwd gate.
2. **Per-phase deletion / size constraints** (phases 1-3, see ADR-0004).
   tighten can only DELETE lines (cannot grow a file). sharpen targets
   only YAML `description` / `when_to_use` (cannot edit the body). lateral
   moves content out of SKILL.md but does not invent new content.
3. **Cap at 3 rounds for phase 4** (AC-3 / HR-5). A 4th attempt in the
   deterministic phase terminates with the literal string
   `"max 3 rounds reached"`. The cap is configurable via
   `--max-rounds <n>` for diagnostic use.
4. **Stagnation auto-exit** (HR-5). In phase 4, two consecutive rounds
   with non-improving `delta_actionable` terminate the loop. Phases 1-3
   are single-pass and have a per-phase regression guard instead: if
   after-phase evaluate raises `actionable`, the phase is auto-reverted
   from snapshot and reported as a regression.

The skill is procedural. It does NOT redefine evaluate's JSON shape or
the fit-finding model — those live in `skills/harness-evaluate/SKILL.md`
and `agents/project-fit-analyzer.md`.

---

## Phase pipeline (v2.1+)

improve runs **4 phases in order**. Default order:
`tighten → lateral → sharpen → deterministic`. The `--phases` flag
selects a comma-separated subset; ordering within the subset is
canonical (you cannot ask for `sharpen,tighten` — it runs as
`tighten,sharpen`).

| Phase | Verb | LLM? | Mutation kind | Cap | Anti-regression |
|-------|------|------|----------------|-----|-----------------|
| 1 | tighten | Yes | line-deletions only | single-pass | post-phase evaluate; revert on `delta_actionable > 0` |
| 2 | lateral | Yes | move sections to `references/<topic>.md`; SKILL.md body gets one-line pointer | single-pass | same |
| 3 | sharpen | Yes | YAML `description` / `when_to_use` rewrite only | single-pass | same |
| 4 | deterministic | No | current v2.0 catalog (stub create / line delete / file delete) | `--max-rounds` (default 3) | HR-5 stagnation streak |

**Phase ordering rationale (ADR-0004).** Subtract before add. Deletion
(phase 1) can only reduce context budget. Lateral (phase 2) restructures
without inventing content. Sharpen (phase 3) targets the highest-leverage
field. Deterministic (phase 4) adds missing coverage last, so it slots
into the now-tightened body. Reordering this chain would re-introduce
the failure modes Karpathy's U-curve and Anthropic's conciseness test
warn against.

**AC-3 reproducibility escape hatch.** `--phases deterministic` runs
only phase 4 — exactly the v2.0 behavior. CI / scripted callers that
need deterministic outputs should use this flag. The other phases
involve LLM calls and are not bit-reproducible across runs.

**`--no-apply`** applies to every phase: the LLM is still called, diffs
are still shown, no writes happen.

---

## Inputs

| Input                      | Source                                                                                     | Required |
| -------------------------- | ------------------------------------------------------------------------------------------ | -------- |
| Target project root        | `--target <path>` arg, else `$PWD`                                                         | Yes      |
| Phase selection            | `--phases <csv>` arg, default `tighten,lateral,sharpen,deterministic`                      | Yes (default) |
| Max rounds (phase 4 only)  | `--max-rounds <n>` arg, default `3`                                                        | Yes (default) |
| Auto-approve per-phase     | `--auto` flag                                                                              | No       |
| Apply mode                 | absent `--no-apply` (apply on by default; `--no-apply` makes the run a pure dry-run)       | No       |
| Plugin install root        | `$CLAUDE_PLUGIN_ROOT` else relative fallback (same pattern as `harness-build`)             | Yes      |

`--max-rounds 0` is `IMPROVE_BAD_ARGS`. `--max-rounds > 10` is also
`IMPROVE_BAD_ARGS` — improve is an interactive verb, not a long-running
batch job.

`--phases` accepts any comma-separated subset of
`{tighten, lateral, sharpen, deterministic}`. Unknown phase names →
`IMPROVE_BAD_ARGS`. Empty list → `IMPROVE_BAD_ARGS`. Duplicates are
de-duplicated; order is normalized to the canonical phase order.
`--phases deterministic` preserves v2.0 behavior exactly (no LLM calls,
AC-3 reproducible).

There is no KB input. The prior `docs/kb-manifest.json` chain is retired.

---

## Outputs

1. **Round-state JSON** atomically written to
   `<target>/.meta-harness/.improve-state.json` after every round
   completes (whether applied, declined, or stagnated). Schema:

   ```jsonc
   {
     "schema_version": 2,
     "improve_version": "2.1.0",
     "meta": {
       "target": "/abs/path",
       "started_at": "2026-05-27T10:30:00Z",
       "ended_at": "2026-05-27T10:42:00Z",
       "phases_requested": ["tighten", "lateral", "sharpen", "deterministic"],
       "phases_executed": ["tighten", "lateral", "sharpen", "deterministic"],
       "max_rounds": 3,
       "auto": false,
       "exit_reason": "max_rounds_reached"
     },
     "rounds": [
       {
         "round_n": 1,
         "phase": "tighten",
         "started_at": "2026-05-27T10:30:00Z",
         "ended_at": "2026-05-27T10:32:00Z",
         "before_fit": { "qualitative": "decent", "findings_total": 4, "findings_high": 1, "findings_medium": 2, "findings_low": 1, "actionable": 3 },
         "after_fit":  { "qualitative": "decent", "findings_total": 4, "findings_high": 1, "findings_medium": 2, "findings_low": 1, "actionable": 3 },
         "delta_actionable": 0,
         "stagnation_streak": 0,
         "proposal_summary": "Delete 12 lines across 3 SKILL.md files per Anthropic conciseness test.",
         "files_changed": ["skills/foo/SKILL.md", "skills/bar/SKILL.md", "CLAUDE.md"],
         "lines_deleted": 12,
         "user_approved": true,
         "applied": true,
         "regressed": false,
         "snapshot_path": ".meta-harness/snapshots/2026-05-27T10-30-00Z/"
       },
       {
         "round_n": 4,
         "phase": "deterministic",
         "started_at": "2026-05-27T10:36:00Z",
         "ended_at": "2026-05-27T10:40:00Z",
         "before_fit": { "qualitative": "decent", "findings_total": 4, "findings_high": 1, "findings_medium": 2, "findings_low": 1, "actionable": 3 },
         "after_fit":  { "qualitative": "good",   "findings_total": 2, "findings_high": 0, "findings_medium": 1, "findings_low": 1, "actionable": 1 },
         "delta_actionable": -2,
         "stagnation_streak": 0,
         "target_finding": { "id": "F-001", "category": "coverage-gap", "severity": "high", "summary": "..." },
         "proposal_summary": "Generate skills/feature-scaffold/SKILL.md stub from F-001.",
         "files_changed": ["skills/feature-scaffold/SKILL.md"],
         "user_approved": true,
         "applied": true,
         "regressed": false,
         "snapshot_path": ".meta-harness/snapshots/2026-05-27T10-36-00Z/"
       }
     ]
   }
   ```

   **Schema-version bump.** v2.0 → v2.1 added the `phase` field on each
   round and `phases_requested` / `phases_executed` on `meta`. Old v2.0
   state files (schema_version 1) are read-compatible: missing `phase`
   defaults to `"deterministic"` for back-compat.

   **`round_n` is monotonic across phases.** Phases 1-3 each produce
   exactly one round entry (round_n 1, 2, 3). Phase 4 produces up to
   `max_rounds` entries starting at round_n 4. `--max-rounds 3` caps
   phase 4 at 3 rounds, not the whole run.

2. **`<target>/.meta-harness/state.json` update.** On every applied round,
   improve refreshes `state.json` with the post-apply `project_tree_hash`
   and `harness_state_hash` (see `harness-manage` §Step 2.4 for the
   shape). This is what makes manage's drift detection cross-tool-consistent.

3. **Human summary** on stdout (one block per round + final exit block):
   - Round header: `── Round N/M ──`
   - Before: `before: <qualitative> — <H>h / <M>m / <L>l (actionable: <H+M>)`
   - Target finding: `addressing: [<severity>] <category> — <summary>`
   - Proposal: one paragraph (≤6 lines) describing the planned change.
   - Diff: unified-diff-style preview.
   - Approval prompt: `Apply this proposal? [y/N]` (or `auto-applied`).
   - After (if applied): `after: <qualitative> — <H>h / <M>m / <L>l (Δactionable: -2)`
   - Streak: `streak: 0/2 (resets on negative Δactionable)`
   - Final block: `EXIT <exit_reason>`.

### `exit_reason` vocabulary (7 normal + 1 failure)

| Value                       | Meaning                                                                                  |
| --------------------------- | ---------------------------------------------------------------------------------------- |
| `max_rounds_reached`        | Phase 4: the `max_rounds + 1`-th deterministic round was attempted; loop terminated per AC-3. |
| `stagnation_auto_exit`      | Phase 4: two consecutive rounds with `delta_actionable >= 0`; loop terminated per HR-5.   |
| `user_declined`             | The user answered N to a per-phase or per-round approval prompt. Subsequent phases skipped. |
| `no_findings_to_address`    | Phase 4 started with `actionable == 0` (no high/medium findings); nothing to do.          |
| `well_aligned`              | Phase 4 started with `fit_assessment.qualitative == "well-aligned"`; harness is fit.      |
| `dry_run_complete`          | `--no-apply` was set; the pipeline ran to completion without writing.                     |
| `pipeline_complete`         | All requested phases completed normally (no early termination, all approvals granted).    |
| `round_apply_failed`        | Step 6 (atomic apply) failed mid-batch; snapshot restored. The ONLY non-zero exit.        |

---

## Pre-flight: HR-3 cwd guard

1. Resolve the target. `--target <path>` if given, else `$PWD`.
2. Resolve symlinks: `resolved=$(cd "$target" 2>/dev/null && pwd -P)`.
3. Reject and exit `IMPROVE_CWD_REJECTED` if `resolved` is `/`, `$HOME`,
   `/tmp`, `/private/tmp`, non-existent, or a symlink to any of the above.
4. **Outer confirmation prompt.** Improve writes to disk; the operator
   must confirm:

   ```
   cwd: <resolved>
   /meta-harness:improve will iterate up to <max_rounds> rounds of
   (evaluate → propose patch → apply → re-evaluate) against this directory.
   Each round shows a diff and asks for approval before applying.
   Proceed? [y/N]
   ```

   `--auto` does NOT skip this prompt — only the per-round inner
   approvals. The outer prompt is the HR-3 / AC-8 cwd gate and is
   non-negotiable.

If declined: `IMPROVE_CWD_REJECTED user_declined_root`, exit non-zero.

---

## Round-state initialization

After the outer prompt passes:

1. Create or read `<target>/.meta-harness/.improve-state.json`. If a
   prior run's state file is present, offer:
   - **`[A]rchive and start fresh`** — move existing to
     `.improve-state.json.<UTC>.bak`. Default.
   - **`[C]ontinue from prior state`** — load `rounds[]`,
     `next_round_n = len(rounds) + 1`, retain stagnation streak. Only
     legal if prior `exit_reason` ∈ {`user_declined`, `no_findings_to_address`,
     `well_aligned`}. Otherwise → archive forced. (The other terminal
     reasons exhausted the round budget or hit unrecoverable conditions.)
   - **`[Q]uit`** — exit `IMPROVE_PREEMPTED`.

   `--auto` defaults to Archive. `--resume` is reserved for v2 — exits
   `IMPROVE_BAD_ARGS` in v2.0.

2. Initialize counters: `next_round_n = 1`, `stagnation_streak = 0`.
3. Parse `--phases <csv>`. Validate against canonical set
   `{tighten, lateral, sharpen, deterministic}`. Empty / unknown values
   → `IMPROVE_BAD_ARGS`. Deduplicate. Normalize order to canonical.
   Record `meta.phases_requested`.
4. Record `meta.started_at`.

---

## Phase pipeline orchestration

After init, iterate over `meta.phases_requested` in canonical order:

```
for phase in canonical_order(phases_requested):
  result = run_phase(phase)
  meta.phases_executed.append(phase)
  if result.exit_reason in {"user_declined", "round_apply_failed"}:
    break   # subsequent phases skipped
  if result.exit_reason == "regressed":
    # phase auto-reverted; do NOT terminate, advance to next
    continue
  if phase == "deterministic":
    # phase 4 owns its own termination (cap, stagnation, well_aligned, etc.)
    break if result.exit_reason != "pipeline_continue"
```

**Phase semantics summary:**

- Phases 1-3 (tighten, lateral, sharpen): single-pass. Each produces
  exactly one round entry. On regression, auto-revert and continue to
  next phase (regression is not a fatal condition; the pipeline
  expects some phases to no-op).
- Phase 4 (deterministic): the v2.0 loop. Multi-round, capped by
  `--max-rounds`. Its own exit_reasons (`max_rounds_reached`,
  `stagnation_auto_exit`, `well_aligned`, etc.) terminate the entire
  pipeline.

**`exit_reason` resolution:**

- If any phase set `user_declined` or `round_apply_failed`, that
  reason wins (the pipeline stopped early).
- If phase 4 ran and set one of its terminal reasons (`max_rounds_reached`,
  `stagnation_auto_exit`, `no_findings_to_address`, `well_aligned`),
  that reason wins.
- If all requested phases completed without early termination,
  `exit_reason = pipeline_complete`.
- `--no-apply` override (`dry_run_complete`) is applied last, as in v2.0.

---

## Phase 1 — tighten (LLM, deletion-only)

Tighten applies Anthropic's literal conciseness test ([Claude Code Docs
— Best Practices](https://code.claude.com/docs/en/best-practices):
*"For each line, ask: 'Would removing this cause Claude to make
mistakes?' If not, cut it."*) to every harness body file. The LLM
proposes line-deletions; it cannot add, rewrite, or move content.

### Targets

Same harness-body glob as `harness-evaluate` Step 2:
`CLAUDE.md`, `AGENTS.md`, `{skills,.claude/skills}/**/SKILL.md`,
`{agents,.claude/agents}/**/*.md`. HR-4 secret-deny-listed paths
filtered. Files under 30 lines skipped (no useful deletions).

### Procedure

1. **Snapshot.** Create `.meta-harness/snapshots/<UTC>/phase-1-tighten/`
   and copy every target file to its mirrored relative path. Single
   rollback record for the phase.
2. **Before-fit.** If phase 1 is the first phase actually executing,
   invoke `harness-evaluate --single` for `before_fit`. Otherwise reuse prior
   phase's `after_fit`.
3. **LLM pass.** For each target file, feed full content + the tighten
   proposer prompt. Model returns
   `{deletions: [{line_range: [start, end], rationale: string}]}`.
   Validate: ranges in-file, non-overlapping, rationale ≥ 10 chars.
   Invalid proposals dropped to stderr.
4. **Aggregate diff.** Unified diff of net deletions across all files.
   Header: `Phase 1 / tighten — proposing N line deletions across M files (Anthropic conciseness test)`.
5. **Approval gate** (NFR-4). `Apply this proposal? [y/N]`. `--auto`
   skips. Decline → record `phase: tighten, user_approved: false`, set
   `exit_reason: user_declined`, skip subsequent phases.
6. **Atomic apply.** For each file with deletions:
   - Compute post-deletion content.
   - **Deletion-only invariant**: verify post-deletion is a strict line
     subset of the snapshot copy (every line in new must appear in
     snapshot, in order). Hash mismatch → fail the phase, restore from
     snapshot.
   - Atomic write via `.tmp.$$` → `mv` (HR-1).
   - Mid-batch failure → restore all files from `phase-1-tighten/`
     snapshot; record `applied: false, regressed: false`.
7. **After-fit + regression guard.** Invoke `harness-evaluate --single` again.
   If `after_fit.actionable > before_fit.actionable` (deletion removed
   load-bearing content), **auto-revert from snapshot**, mark
   `regressed: true`, continue to next phase. The phase did not apply.
   Otherwise keep.
8. **Record the round.** `phase: "tighten"`, `round_n` = next number,
   `files_changed`, `lines_deleted`. Atomic write `.improve-state.json`.

### Tighten proposer prompt

System: *"You are applying the Anthropic Claude Code conciseness test
to a harness instruction file. For each line, ask: 'Would removing this
cause Claude to make mistakes?' Return ONLY a JSON object
`{deletions: [{line_range: [start, end], rationale: string}]}` for
proposed deletions. Do NOT propose additions, rewrites, or
line-reorderings. Be conservative — when in doubt, do not propose. The
operator reviews every proposed deletion."*

The conservative bias matters: over-deletion is caught by the
regression guard, but a conservative pass produces a small reviewable
diff. The deletion-only invariant + auto-revert means tighten CANNOT
produce a harness worse than its input.

---

## Phase 2 — lateral (LLM, structural extraction)

Lateral applies Anthropic's progressive-disclosure pattern (L1
metadata / L2 SKILL.md body / L3 bundled references — [Anthropic
Engineering blog](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills))
by moving heavy sections out of SKILL.md bodies into
`references/<topic>.md` files. The body retains a one-line pointer.

### Targets

SKILL.md files (legacy `skills/` + canonical `.claude/skills/`) where
the body exceeds **300 lines** OR contains a single section longer than
**100 lines**. Below these thresholds, lateral has nothing to do.

### Procedure

1. **Snapshot.** `.meta-harness/snapshots/<UTC>/phase-2-lateral/`. Copy
   every target SKILL.md AND its parent skill directory (existing
   `references/` content must be preserved).
2. **LLM pass.** For each target SKILL.md, feed full content + a list
   of existing `references/*.md` filenames + the lateral proposer
   prompt. Model returns
   `{extractions: [{source_range, target_file, pointer_line}]}`.
   Validate:
   - source_ranges non-overlapping
   - target_file path under the same skill directory
   - pointer_line contains a working relative markdown link
   - source_range size ≥ 30 lines (small sections aren't worth the indirection)
3. **Aggregate diff.** Per-file unified diff (removed sections +
   pointer line) plus creation diff per new `references/*.md`. Header:
   `Phase 2 / lateral — proposing K extractions across M skills (progressive disclosure)`.
4. **Approval gate.** Same as phase 1.
5. **Atomic apply.** For each extraction:
   - Write the extracted content to `references/<topic>.md` (atomic,
     HR-1). If the target file exists, append with separator
     `\n\n## (extracted from SKILL.md on YYYY-MM-DD)\n`.
   - Atomically rewrite source SKILL.md replacing the source_range
     with the pointer_line.
6. **After-fit + regression guard.** If the analyzer now reports a
   stale-reference finding pointing at the new `references/*.md` (e.g.,
   the pointer link format the analyzer can't follow), revert.
7. **Record the round.** `phase: "lateral"`, `files_changed` lists
   rewritten SKILL.md + created references.

### Lateral proposer prompt

System: *"You are applying Anthropic's progressive-disclosure pattern.
The SKILL.md body is the L2 layer (loaded every activation, recurring
token cost). Move heavy reference material — API tables, long
examples, detailed background — to a `references/<topic>.md` file (L3,
loaded only when navigated). KEEP inline: step-by-step instructions,
short examples, the procedure spine. Return ONLY the extractions JSON.
Do NOT propose extractions under 30 lines."*

---

## Phase 3 — sharpen (LLM, YAML-description-only)

Sharpen rewrites the YAML `description` and (where present)
`when_to_use` fields of skills and agents to improve trigger accuracy.
Anthropic skill-creator notes Claude tends to *"undertrigger"* skills;
descriptions should be a little bit pushy. The body is **never**
touched by this phase.

### Targets

Every SKILL.md and agent .md (legacy + `.claude/`) with a YAML
frontmatter `description` field. HR-4 paths filtered.

### Procedure

1. **Snapshot.** `.meta-harness/snapshots/<UTC>/phase-3-sharpen/`. Copy
   every target file (we only edit frontmatter, but snapshot the whole
   file for trivial rollback).
2. **LLM pass.** For each target file, read the YAML frontmatter + the
   first ~50 lines of the body, feed to the model with the sharpen
   prompt. Model returns
   `{description, when_to_use?, rationale}`. Validate:
   - combined `description` + `when_to_use` ≤ 1,500 chars (Anthropic
     structural cap is 1,536; 36-char buffer)
   - each field ≥ 30 chars (no empty rewrites)
   - rationale ≥ 20 chars
3. **Aggregate diff.** Before/after for each frontmatter description
   block. Header: `Phase 3 / sharpen — proposing N description rewrites (trigger-accuracy)`.
4. **Approval gate.** Same as phases 1-2.
5. **Atomic apply.** Read frontmatter, replace `description` and
   `when_to_use` only, atomically write back. **Body-untouched
   invariant**: hash the body section before/after; mismatch → abort
   this file's update, restore from snapshot.
6. **After-fit + regression guard.** Same as phases 1-2.
7. **Record the round.** `phase: "sharpen"`.

### Sharpen proposer prompt

System: *"You are rewriting a Claude Code skill / agent description
for trigger accuracy. Anthropic notes Claude undertriggers skills;
descriptions should be specific about WHEN to use this skill (use 'Use
when ...' phrasing), how it differs from related skills, and include
1-2 concrete trigger phrases the user might type. Target 200-300
chars for description. Avoid generic phrasing like 'this skill helps
with X'. Be a little bit pushy."*

---

## Phase 4 — deterministic loop (per-round procedure)

Phase 4 is the v2.0 deterministic improve loop: up to `--max-rounds`
iterations of (evaluate → pick top finding → propose patch → user
approval → atomic apply + snapshot → re-evaluate → record state). With
`--phases deterministic` this is the ONLY phase that runs, and the
behavior is byte-identical to v2.0 (AC-3 reproducible).

Each round executes the following 8 steps. If a step fails, the round
is rolled back and the loop terminates with `IMPROVE_ROUND_FAILED`.

### Step 1 — Cap check (AC-3)

```bash
if [ "$next_round_n" -gt "$max_rounds" ]; then
  printf "max %d rounds reached\n" "$max_rounds"
  exit_reason="max_rounds_reached"
  goto FINALIZE
fi
```

This is the AC-3 binding. **The check runs at the top of the round,
BEFORE any evaluate/propose/apply work.** A 4th-round attempt prints the
literal string `"max 3 rounds reached"` and does NOT execute any apply
step. Verification: `grep -F "max ${max_rounds} rounds reached"` on
stdout, combined with `jq -e '.rounds | length == max_rounds'` on the
state file.

### Step 2 — Before-fit (evaluate)

Invoke `skills/harness-evaluate --single` against the target. Capture the
JSON result. Extract:

> **All internal evaluate calls pin `--single` (ADR-0006).** Since v3.0.0
> `evaluate` defaults to the debate panel; improve MUST pin `--single` on
> every before/after-fit and regression-guard call. This keeps phase 4
> **byte-reproducible (AC-3)** and keeps the HR-5 stagnation streak and the
> phase 1-3 regression auto-revert on the **AC-6 ±1 band** (both rely on the
> single pass). A debated evaluate here would break both.

- `fit_assessment.qualitative`
- `fit_assessment.coverage_gaps + over_coverage + stale_references + pain_patterns` → `findings_total`
- For each severity tier, count: `findings_high`, `findings_medium`, `findings_low`
- `actionable = findings_high + findings_medium`
- The full `findings[]` array (needed by Step 3)

If evaluate fails (e.g., `EVAL_INVALID_JSON` after retry), fail this
round → `IMPROVE_ROUND_FAILED`.

#### Early-exit gates

After capturing the before-fit:

- If `fit_assessment.qualitative == "well-aligned"` → `exit_reason = "well_aligned"`, goto FINALIZE.
  The harness is fit; no proposals are needed.
- If `actionable == 0` (only low-severity findings remain) →
  `exit_reason = "no_findings_to_address"`, goto FINALIZE.
  v2.0 doesn't auto-fix low-severity findings; operators can address
  them manually or via direct edits.

### Step 3 — Pick the target finding

From `findings[]`, select the **single** top-priority finding to address
this round:

1. Filter to actionable severities: `{high, medium}`.
2. Sort:
   - `severity = high` before `medium`.
   - Within same severity, prefer categories in order:
     `stale-reference` (smallest blast radius, cleanest delete) →
     `over-coverage` (delete) →
     `coverage-gap` (additive) →
     `pain-pattern` (additive).
   - Within same (severity, category), sort by `id` lexicographically.
3. Take the first finding from the sorted list. This is `target_finding`.

One finding per round is intentional. It keeps each diff small enough for
human review and makes the before/after delta attributable to that
specific change.

### Step 4 — Compose the proposal

The proposer is **deterministic**, no LLM call. It maps `target_finding`
into a concrete write plan based on the finding's category:

| `target_finding.category` | Proposed change                                                                                                                                                                                                          |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `coverage-gap`            | Generate a stub at `skills/<slug>/SKILL.md` (or `agents/<slug>.md`) from the same skeleton `harness-build` Step 5 uses. Slug derivation and skill-vs-agent decision are identical to `harness-build` Step 5.2 + 5.3.       |
| `pain-pattern`            | Same as `coverage-gap` — generate a stub. The finding's `suggested_action` populates the stub's description.                                                                                                              |
| `stale-reference`         | Locate the offending line in the named harness file (one of `evidence[*].ref` with `kind: "harness-path"`). Propose a unified-diff patch that DELETES the line, OR replaces the dead reference with `<REMOVED>` if the line cannot be confidently deleted (e.g., it's a frontmatter field). |
| `over-coverage`           | Propose deleting the harness file the finding names (`evidence[*].ref` with `kind: "harness-path"`). Move it to the snapshot dir as part of Step 6 instead of `rm -f` so the operator can recover.                        |

#### 4.1 Stub generation (coverage-gap / pain-pattern)

The stub uses the same templates `harness-build` consumes:
`<plugin_root>/templates/capabilities/skills/_stub/SKILL.md.tpl` or
`<plugin_root>/templates/persona/agents/_stub.md.tpl`, with the same
placeholders (`{{skill_id}}`, `{{skill_description}}`, etc.). The stub is
a placeholder the operator fills in afterward — improve does NOT attempt
to write a full skill body.

#### 4.2 Stale-reference deletion (stale-reference)

For each `evidence` entry with `kind == "harness-path"`:

1. Read the file at `evidence.ref`.
2. Identify the line containing the dead reference (the evidence `note`
   often names the line number or pattern).
3. If the dead reference is the entire line (e.g., a list item, a bare
   path mention), propose `delete line N`.
4. If the dead reference is part of a longer line (e.g., a sentence in
   a paragraph), propose replacing the substring with `<REMOVED>` and
   appending a comment line `<!-- meta-harness: stale ref to '<old>' removed on YYYY-MM-DD -->`.

The diff is constructed line-by-line. No LLM rewrite.

#### 4.3 Over-coverage removal (over-coverage)

For each `evidence` entry with `kind == "harness-path"` naming the
unused file:

1. The "removal" is implemented as: move the file into the round's
   snapshot directory (Step 6.1) and emit a delete diff.
2. The operator approves the deletion via the standard approval gate.
3. If the file is part of a directory that becomes empty after removal,
   note this in the proposal summary; do NOT auto-remove the empty
   directory in v2.0 (a follow-up `find -type d -empty -delete` is
   left to the operator).

#### 4.4 No-proposal escape hatch

If `target_finding`'s evidence does not contain a harness-path that maps
to a concrete change (e.g., a stale-reference finding whose evidence
only cites a project-absent path, leaving improve with no harness file
to edit), the proposal is **advisory-only**:

- Render the proposal text with a one-line note: `(advisory only — no
  concrete patch derivable from finding evidence)`.
- The approval prompt still appears; on `y`, the round records
  `applied: false, delta_actionable: 0`, and the loop continues to the
  next round. This is a normal exit-less event — it does NOT set
  `exit_reason`.

### Step 5 — Approval gate (NFR-4)

1. Render the proposal text (≤6 lines).
2. Render the file-change diff. For advisory-only, the diff section reads
   `(no changes — advisory only)`.
3. Prompt: `Apply this proposal? [y/N]`. Default N.
4. `--auto` skips this prompt and treats the answer as `y`.
5. If the user answers N: record `user_approved: false`, `applied: false`,
   set `exit_reason: user_declined`, write round-state, goto FINALIZE.

### Step 6 — Atomic apply + snapshot

Reached only if `user_approved == true` AND the proposal is not
advisory-only.

1. Create the snapshot dir if not already created this run:
   `snap="$resolved/.meta-harness/snapshots/$(date -u +%Y%m%dT%H%M%SZ)/phase-4-deterministic"`.
2. For each file in `files_changed`:
   - If the file exists, copy it to `$snap/<relative-path>`. (For
     over-coverage removals, this copy IS the rollback record — the
     subsequent step deletes the original.)
   - For creates and edits: atomically write the new content via
     `<dest>.tmp.$$` → `mv` (NFR-4, HR-1).
   - For deletes (over-coverage only): after the snapshot copy succeeds,
     `rm "$dest"`.
3. On any mid-batch failure:
   - For files written this round: `rm -f "$dest"`.
   - For files overwritten: restore from `$snap/<relative-path>`.
   - For files deleted: restore from `$snap/<relative-path>`.
   - Mark round as `applied: false, delta_actionable: 0,
     exit_reason: round_apply_failed`.
   - Exit `IMPROVE_ROUND_FAILED` (non-zero).

4. **`--no-apply`** mode: Step 6 is skipped entirely. `applied: false`,
   `delta_actionable: 0`, snapshot path omitted.

### Step 7 — After-fit (re-evaluate)

Reached only if Step 6 actually applied changes (i.e., not `--no-apply`,
not user-declined, not advisory-only). Otherwise `after_fit = before_fit`
and `delta_actionable = 0`.

Invoke `harness-evaluate --single` again. Capture the new counts. Compute:

```
delta_actionable = after_fit.actionable - before_fit.actionable
```

**Improvement means `delta_actionable < 0`** (fewer high+medium findings).
A non-negative delta is non-improvement. (Note: this inverts the v1
"positive delta = good" sign because v2 counts findings, not scores.)

### Step 8 — Round-state record + stagnation check

1. Update streak:
   ```
   if delta_actionable >= 0: stagnation_streak += 1
   else:                     stagnation_streak = 0
   ```
2. Append the round record to `rounds[]`.
3. **Refresh `state.json`** (the file `harness-manage` reads) with the
   post-apply project_tree_hash and harness_state_hash, plus
   `recorded_by: "harness-improve"`. Atomic write.
4. Atomically rewrite `.improve-state.json`.
5. Stagnation check (HR-5):
   ```
   if stagnation_streak >= 2:
     exit_reason = "stagnation_auto_exit"
     goto FINALIZE
   ```
6. Otherwise: `next_round_n += 1`, loop back to Step 1.

---

## FINALIZE — write `meta.exit_reason` and emit summary

When the pipeline exits (any phase set `user_declined` /
`round_apply_failed`; phase 4 hit Step 1 cap, Step 2 early-exit, Step 8
stagnation; or all phases completed normally):

1. **Resolve `exit_reason`** per the orchestration rules above (early
   termination wins; otherwise phase-4 terminal reason; otherwise
   `pipeline_complete`).
2. **`--no-apply` override.** If the run was launched with `--no-apply`,
   replace the natural `exit_reason` with `dry_run_complete` before the
   state file is written. Single override point. `round_apply_failed` is
   not overridden because Step 6 (where it is set) is skipped under
   `--no-apply`.
3. Set `meta.ended_at` and finalize `meta.phases_executed`.
4. Atomically write the final `.improve-state.json` (HR-1).
5. Emit `EXIT <exit_reason>` and the human summary (one block per
   executed phase + final exit block).
6. Return 0 for the seven normal reasons; return
   `IMPROVE_ROUND_FAILED`'s non-zero code for `round_apply_failed`.

---

## Stagnation detector — honest disclosure

The rule "2 consecutive rounds with `delta_actionable >= 0`" is
intentionally conservative.

- **One bad round alone is not enough.** A single round with
  `delta_actionable == 0` (e.g., advisory-only) does NOT trigger
  stagnation; the streak counter starts. Stagnation fires on the *second*
  consecutive non-improving round.
- **`delta_actionable == 0` counts as non-improvement.** An applied
  proposal that produces no measurable change in the actionable-count is
  treated as "didn't help". This is honest: the analyzer's evaluator
  noise (AC-6 ±1 finding) means a 0-delta is within noise, but improve
  cannot tell signal from noise without multiple samples.
- **The streak resets on the first negative delta** (improvement).
- **The user-declined round terminates the loop** (Step 5 goto FINALIZE)
  before stagnation can advance — declined rounds never participate in
  the streak in v2.0.
- **A new finding appearing post-apply** (e.g., the patch created a new
  stale-reference) can push `actionable` upward and produce a positive
  delta. The streak treats that as non-improvement and counts it. This
  is intentional — improve should not loop while regressing.

---

## Failure modes

| Code                         | Meaning                                                                                                                | Exit |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ---- |
| `IMPROVE_CWD_REJECTED`       | Pre-flight refused the target, or operator declined the outer cwd prompt. No reads or writes.                          | 1    |
| `IMPROVE_BAD_ARGS`           | Contradictory or out-of-range argv (`--max-rounds 0`, `> 10`, `--resume` reserved).                                    | 4    |
| `IMPROVE_ROUND_FAILED`       | An evaluate / apply step failed mid-round. State file updated to record the failed round; snapshots restored.          | 5    |
| `IMPROVE_PREEMPTED`          | Operator quit at the prior-state choice prompt before any round started.                                               | 6    |
| `IMPROVE_STATE_WRITE_FAILED` | Round completed but `.improve-state.json` atomic write failed. In-memory state lost; applied edits are NOT rolled back. | 7    |

The seven normal `exit_reason` values (`max_rounds_reached`,
`stagnation_auto_exit`, `user_declined`, `no_findings_to_address`,
`well_aligned`, `dry_run_complete`, `pipeline_complete`) are NOT
failures — they return 0.

---

## AC-3 contract (binding, v2 form — phase 4 only)

> When `/meta-harness:improve --phases deterministic --max-rounds 3
> --auto` runs against a fixture harness that has at least 3
> actionable findings per round (sufficient to keep the loop going),
> phase 4 MUST execute at most 3 apply-eligible rounds. A 4th round
> attempt MUST print `"max 3 rounds reached"` on stdout AND set
> `meta.exit_reason == "max_rounds_reached"` in the state file. The
> state file's `rounds` array MUST have length exactly 3 and every
> round MUST have `phase == "deterministic"`.

The `--phases deterministic` flag is part of the contract because v2.1
adds LLM phases by default. Callers depending on AC-3 reproducibility
MUST pin to `--phases deterministic`.

Mechanical verification:

```bash
# Fixture: a project + harness with enough coverage gaps that proposals
# keep firing for 3 rounds. (Constructed by adding 4+ unrelated TODO
# directories the analyzer flags as coverage-gap.)
/meta-harness:improve --target /tmp/m5-fixture \
  --phases deterministic --auto --max-rounds 3

# Check 1: stdout includes the cap message
last_stdout=$(... captured ...)
echo "$last_stdout" | grep -F "max 3 rounds reached" >/dev/null || exit 1

# Check 2: state file shows exactly 3 rounds + correct exit_reason
jq -e '.rounds | length == 3' /tmp/m5-fixture/.meta-harness/.improve-state.json
jq -e '.meta.exit_reason == "max_rounds_reached"' /tmp/m5-fixture/.meta-harness/.improve-state.json
jq -e 'all(.rounds[]; .phase == "deterministic")' /tmp/m5-fixture/.meta-harness/.improve-state.json
```

All three `jq -e` invocations must exit 0.

---

## HR-5 stagnation contract

> When two consecutive rounds produce `delta_actionable >= 0`, the loop
> terminates immediately. The state file's `meta.exit_reason` MUST be
> `"stagnation_auto_exit"`. The state file's `rounds` array length MUST
> equal the number of rounds actually executed (≤ max_rounds).

Exercised by a fixture where the analyzer's findings produce only
advisory-only proposals (every coverage-gap's evidence cites
project-absent refs that improve can't auto-fix) two rounds in a row
after a Round-1 success. The proposer is deterministic, so the behavior
is reproducible.

In v2.1, phases 1-3 are LLM-based; their reproducibility is **not**
guaranteed by AC-3. AC-3 binds only `--phases deterministic`. Callers
that depend on byte-reproducible output (CI gates, golden-file tests)
MUST pin `--phases deterministic`.

---

## Diff preview format (NFR-4)

For every file change `files_changed[i]`, the approval gate renders a
unified diff:

```
--- a/<path>          (snapshot copy, or /dev/null for creates)
+++ b/<path>          (proposed, or /dev/null for deletes)
@@ -1,3 +1,5 @@
 existing line
+new line
+new line
 existing line
```

Diff generation uses `diff -u` (POSIX). The diff is for human review;
the actual write uses the new file's full content.

For over-coverage removals, the diff reads as a pure deletion (`+++
/dev/null`). For stale-reference single-line deletions, the diff shows
a single `-line removed`. For stub creation, the diff is `--- /dev/null
+++ b/skills/<slug>/SKILL.md` showing the full new content.

---

## Out of scope for v2.1

- **LLM-based body rewriting.** v2.1 LLM phases are *constrained*:
  tighten can only delete, lateral can only move, sharpen can only edit
  YAML frontmatter. Free-form body rewriting (rewriting SKILL.md prose
  for "richness") is explicitly NOT a phase — Hamel's *"if you delegate
  this task to an automated tool too early, you risk never fully
  understanding your own requirements or the model's failure modes"*
  warning ([source](https://hamel.dev/blog/posts/evals-faq/should-i-stop-writing-prompts-manually-in-favor-of-automated-tools.html))
  applies directly. Body rewriting is deferred to a future eval-gated
  phase (see ADR-0004).
- **Multi-finding rounds in phase 4.** One deterministic round
  addresses one finding. Tackling several findings per round is v2.x —
  it would complicate the diff preview and the rollback contract.
- **Cross-round memory of declined proposals.** If the operator declines
  the same proposal twice across runs, improve will propose it a third
  time. v2.x may introduce a `.muted_findings` list.
- **Concurrent improve runs against the same target.** Not protected by
  a lockfile.
- **Low-severity auto-fixes.** v2.1 only acts on high + medium findings
  in phase 4. Phases 1-3 act on file shape, not findings.
- **Token-budget enforcement.** Phases 1-3 produce diffs the operator
  reviews; there is no automated "this skill must be ≤ N tokens" gate.
  ADR-0004 considers this for a future phase.

---

## See also

- `commands/improve.md` — the thin user-facing trigger.
- `skills/harness-evaluate/SKILL.md` — invoked per phase (before-fit +
  regression guard) and per phase-4 round (before/after fit).
- `skills/harness-build/SKILL.md` — owns the stub generation templates
  phase 4 reuses for coverage-gap / pain-pattern findings.
- `skills/harness-manage/SKILL.md` — reads the same `state.json` improve
  writes; the two skills agree on drift via shared hash.
- `agents/project-fit-analyzer.md` — produces the findings phase 4
  consumes.
- `docs/adr/ADR-0004-phase-pipeline.md` — rationale for the
  `tighten → lateral → sharpen → deterministic` ordering, the
  deletion-first principle, and the Hamel-compliant eval-gate
  constraints on each LLM phase.
