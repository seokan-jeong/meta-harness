---
name: improve
description: "Iteratively improve a project harness toward better fit. Runs a 4-phase pipeline: (1) tighten — LLM proposes line-deletions per Anthropic's conciseness test; (2) lateral — moves heavy sections to references/*.md; (3) sharpen — rewrites YAML descriptions for trigger-accuracy; (4) deterministic — the v2.0 3-round loop. Each phase has its own approval gate. --phases selects a subset; --phases deterministic preserves the v2.0 contract (AC-3 reproducible)."
argument-hint: "[--target <path>] [--phases <csv>] [--auto] [--max-rounds <n>] [--no-apply]"
allowed-tools:
  - Read
  - Edit
  - Write
  - Glob
  - Grep
  - Bash
  - Task
model: inherit
---

# `/meta-harness:improve` — phase-pipeline fit-improvement

This is the thin trigger for the improve workflow. The phase pipeline,
state machine, proposer logic, and termination rules live in
`skills/harness-improve/SKILL.md`. This command's job is to enforce the
cwd guard (HR-3), parse arguments, and dispatch.

Improve is the only verb (beyond first-time build) that **modifies the
target harness on disk**. Two consent gates protect against runaway
edits:

1. **Outer cwd prompt** (mandatory, not skippable by `--auto`).
2. **Per-phase approval prompt** (skippable by `--auto`). Phase 4 also
   has per-round approval prompts inside the loop.

The 3-round cap is the AC-3 binding (phase 4 only — pin via
`--phases deterministic` to reproduce v2.0). Stagnation auto-exit
(2 consecutive `delta_actionable >= 0`) is the HR-5 binding (phase 4
only). Phases 1-3 have their own per-phase regression guard: if the
analyzer's `actionable` count rises after a phase, the phase is
auto-reverted from snapshot.

## When to use this

- `/meta-harness:evaluate` reports `fit_assessment.qualitative` is
  `decent` or `draft` and you want an interactive loop to address the
  high/medium findings.
- `/meta-harness:manage` reports `drift.drifted == true` and you want
  to re-align the harness without a full re-build.

If the target has NO harness yet, use `/meta-harness:build` first. If
you just want a one-shot fit-assessment, use `/meta-harness:evaluate`.

## Arguments

| Argument | Default | Meaning |
|----------|---------|---------|
| `--target <path>` | current working directory | Project root to improve. Same constraints as build/manage. |
| `--phases <csv>` | `tighten,lateral,sharpen,deterministic` | Comma-separated subset of `{tighten, lateral, sharpen, deterministic}` to run. Order normalized to canonical. Unknown / empty → `IMPROVE_BAD_ARGS`. `--phases deterministic` preserves v2.0 behavior exactly (AC-3 reproducible). |
| `--auto` | off | Skip the **per-phase** and **per-round** approval prompts. Does NOT skip the **outer** cwd prompt. |
| `--max-rounds <n>` | 3 | Phase-4 cap. Range `[1, 10]`. Out-of-range → `IMPROVE_BAD_ARGS`. Does NOT apply to phases 1-3 (each is single-pass). |
| `--no-apply` | off | Dry-run mode: run the full pipeline including LLM phases + diff display, but skip all apply steps. `applied: false` for every round; `exit_reason: dry_run_complete`. |
| `--resume` | off (reserved) | Reserved for v2.x; v2.0 → `IMPROVE_BAD_ARGS`. The v2.0 resume path is the interactive Archive/Continue/Quit prompt at run start. |

`--auto` and `--no-apply` together is legal.

### Phase selection — common patterns

```bash
# Default — full pipeline (4 phases)
/meta-harness:improve

# Subtract-only run (no additive changes)
/meta-harness:improve --phases tighten

# v2.0 byte-compatible (AC-3 reproducible; pin for CI / golden tests)
/meta-harness:improve --phases deterministic --auto --max-rounds 3

# Description-sharpen pass (highest-leverage field per Anthropic)
/meta-harness:improve --phases sharpen

# Tighten + sharpen, skip lateral & deterministic
/meta-harness:improve --phases tighten,sharpen
```

## Pre-flight (HR-3) — performed BEFORE any read of the harness

1. Resolve the target. `--target <path>` if given, else `$PWD`. Resolve
   symlinks portably with `pwd -P`.
2. Reject and exit `IMPROVE_CWD_REJECTED` if the resolved path is `/`,
   `$HOME` exactly, `/tmp` / `/private/tmp`, non-existent, or a symlink
   to any of those.
3. Show the resolved path and the planned phase pipeline, then ask:
   ```
   cwd: <resolved>
   /meta-harness:improve will run phases [<phases_csv>] against this
   directory. LLM phases (tighten/lateral/sharpen) may invoke the model
   to propose deletions / structural moves / description rewrites.
   Phase 4 (deterministic) iterates up to <max_rounds> rounds. Each
   phase shows a diff and asks for approval before applying (--auto
   skips per-phase / per-round prompts but not this one).
   Proceed? [y/N]
   ```
   Default N. N → exit `IMPROVE_CWD_REJECTED user_declined_root`.

## What this command writes

Three artifact classes. All writes are atomic and snapshot-backed:

1. **`<target>/.meta-harness/.improve-state.json`** — round-state
   record, rewritten after every round (including phase-1/2/3 rounds).
   Schema v2 in `skills/harness-improve/SKILL.md` §Outputs.
2. **`<target>/.meta-harness/state.json`** — refreshed after every
   successful apply with the new `project_tree_hash` and
   `harness_state_hash`. This is what `manage` reads for drift detection.
3. **Files changed per phase**:
   - Phase 1 (tighten): existing harness body files (lines removed).
   - Phase 2 (lateral): SKILL.md bodies (sections replaced by pointers)
     + new `references/<topic>.md` files.
   - Phase 3 (sharpen): YAML frontmatter `description` / `when_to_use`
     of skills + agents.
   - Phase 4 (deterministic): per finding —
     `coverage-gap` / `pain-pattern` → new stub at
     `.claude/skills/<slug>/SKILL.md` or `.claude/agents/<slug>.md`;
     `stale-reference` → in-place edit removing the dead reference;
     `over-coverage` → file moved into the snapshot directory (deletion).

`--no-apply` skips artifacts 2 and 3; artifact 1 is still written (the
audit trail).

## Procedure (delegated)

Once both the cwd guard and the outer prompt pass, this command hands
off to the `harness-improve` skill, which orchestrates the requested
phases in canonical order:

1. Initialize round-state (archive prior `.improve-state.json` if present).
2. **Phase 1 — tighten** (if requested). LLM proposes line-deletions
   per Anthropic's conciseness test. Approval gate + atomic apply +
   regression guard (auto-revert if `actionable` rises).
3. **Phase 2 — lateral** (if requested). LLM proposes moving heavy
   sections to `references/<topic>.md`. Same gate + apply + guard.
4. **Phase 3 — sharpen** (if requested). LLM rewrites YAML
   `description` / `when_to_use`. Same gate + apply + guard.
5. **Phase 4 — deterministic** (if requested). The v2.0 loop:
   - Step 1 — cap check (AC-3); if exceeded, print "max N rounds
     reached" and exit.
   - Step 2 — evaluate (before_fit). Early-exit on `well_aligned` or
     `no_findings_to_address`.
   - Step 3 — pick the single top-priority finding for this round.
   - Step 4 — compose the proposal (deterministic mapping by category).
   - Step 5 — approval gate (skippable per `--auto`).
   - Step 6 — atomic apply + snapshot (skipped under `--no-apply`).
   - Step 7 — re-evaluate (after_fit), compute `delta_actionable`.
   - Step 8 — record round-state + state.json, update stagnation
     streak, check HR-5.
6. Finalize: resolve `meta.exit_reason` (early-termination wins;
   otherwise phase-4 terminal reason; otherwise `pipeline_complete`),
   summary block on stdout.

See `skills/harness-improve/SKILL.md` for the authoritative procedure
including per-phase proposer prompts, the deletion-only invariant
(phase 1), the body-untouched invariant (phase 3), and the rollback
contract.

## Verification — AC-3 (phase-4 3-round cap)

AC-3 binds only `--phases deterministic`. Pin the flag to reproduce
the v2.0 contract:

```bash
# Bootstrap a fixture with enough coverage gaps that proposals fire 3 rounds.
/meta-harness:build --target /tmp/m5-fixture --accept-all
# (add fixture content here to ensure analyzer finds 3+ actionable findings)

# Run improve in v2.0-compatible mode.
/meta-harness:improve --target /tmp/m5-fixture \
  --phases deterministic --auto --max-rounds 3 \
  | tee /tmp/m5-improve.log

# AC-3 Check 1: cap message on stdout
grep -F "max 3 rounds reached" /tmp/m5-improve.log \
  || { echo "AC-3 stdout FAIL" >&2; exit 1; }

# AC-3 Check 2: state file shows exactly 3 rounds
jq -e '.rounds | length == 3' \
  /tmp/m5-fixture/.meta-harness/.improve-state.json

# AC-3 Check 3: exit_reason is max_rounds_reached
jq -e '.meta.exit_reason == "max_rounds_reached"' \
  /tmp/m5-fixture/.meta-harness/.improve-state.json

# AC-3 Check 4 (v2.1): every recorded round is phase=deterministic
jq -e 'all(.rounds[]; .phase == "deterministic")' \
  /tmp/m5-fixture/.meta-harness/.improve-state.json
```

All four checks must pass. The full procedure also exercises HR-5
(stagnation auto-exit) via a different fixture — see the skill.

## Failure modes (must surface on stderr)

| Code | Meaning |
|------|---------|
| `IMPROVE_CWD_REJECTED` | Pre-flight refused the target, or operator declined the outer prompt. |
| `IMPROVE_BAD_ARGS` | Contradictory or out-of-range argv (`--max-rounds 0`, `> 10`, `--resume` present). |
| `IMPROVE_ROUND_FAILED` | An evaluate / apply step failed mid-round. State file updated; partial writes rolled back via snapshot. |
| `IMPROVE_PREEMPTED` | Operator quit at the prior-state choice prompt before any round started. |
| `IMPROVE_STATE_WRITE_FAILED` | Round completed but `.improve-state.json` atomic write failed. Applied edits are NOT rolled back. |

The seven normal `exit_reason` values (`max_rounds_reached`,
`stagnation_auto_exit`, `user_declined`, `no_findings_to_address`,
`well_aligned`, `dry_run_complete`, `pipeline_complete`) are NOT
failures — process returns 0.

## Examples

```bash
# Default — full 4-phase pipeline against current directory.
/meta-harness:improve

# Dry-run: see what each phase WOULD do, no writes.
/meta-harness:improve --no-apply

# v2.0-compatible / AC-3 reproducible: only the deterministic phase.
/meta-harness:improve --phases deterministic --auto --max-rounds 3

# Subtract-only run: just tighten + lateral, no additive changes.
/meta-harness:improve --phases tighten,lateral

# Description-only sharpen pass (highest-leverage field per Anthropic).
/meta-harness:improve --phases sharpen

# Diagnostic: extended phase-4 loop.
/meta-harness:improve --phases deterministic --max-rounds 5

# Inspect the round-state of the last run (note: now grouped by phase).
jq '.meta, (.rounds | map({round_n, phase, delta_actionable, applied, regressed}))' \
  .meta-harness/.improve-state.json
```

## Related

- `skills/harness-improve/SKILL.md` — authoritative procedural workflow
  including per-phase proposer prompts + invariants.
- `commands/evaluate.md` — invoked once per phase (before-fit +
  regression guard) and once per phase-4 round (before/after fit).
- `commands/build.md` — owns the stub templates phase 4 reuses for
  coverage-gap / pain-pattern findings.
- `commands/manage.md` — reads the `state.json` improve writes; the two
  agree on drift via shared hash.
- `ADR-0003` — reason hook-based auto-improve is opt-in default-OFF.
- `ADR-0004` — phase-pipeline ordering rationale + the deletion-first
  principle (Karpathy U-curve + Anthropic conciseness test +
  Hamel "no auto-rewrite without evals").
