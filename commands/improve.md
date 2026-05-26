---
name: improve
description: "Iteratively improve a project harness. Up to 3 rounds of (evaluate → manage → rule-based propose → user approval → atomic apply → re-evaluate). Stagnation auto-exit on 2 consecutive non-improvements; hard cap at 3 rounds per AC-3."
argument-hint: "[--target <path>] [--auto] [--max-rounds <n>] [--no-apply]"
allowed-tools:
  - Read
  - Edit
  - Write
  - Glob
  - Grep
  - Bash
model: inherit
---

# `/meta-harness:improve` — iterative harness improvement loop

This is the thin trigger for the improve workflow. The actual state machine,
proposer catalogue, and termination logic live in the `harness-improve`
skill (`skills/harness-improve/SKILL.md`); this command's job is to enforce
the cwd guard (HR-3), parse arguments, and dispatch to the skill.

Improve is the only verb in v1 that **modifies the target harness on disk**.
Two consent gates protect against runaway edits:

1. **Outer cwd prompt** (mandatory, not skippable by `--auto`): cwd is
   shown and the operator must confirm "Proceed?" before any round runs.
2. **Per-round approval prompt** (skippable by `--auto`): each proposal's
   diff is displayed and the operator approves or declines before apply.

The 3-round cap is the AC-3 binding. The stagnation auto-exit (2
consecutive `delta ≤ 0`) is the HR-5 binding.

## When to use this

Run improve when you have an existing harness, you have already inspected
it with `/meta-harness:evaluate` or `/meta-harness:manage`, and you want
an interactive loop to address the lowest-hanging structural issues.
Typical situations:

- **Score is below 12/20** and `/meta-harness:manage` reports missing
  buckets or a stale vendored evaluator — improve's P1–P3 proposals can
  fix those structurally.
- **Healthcheck is clean but the operator wants advisory suggestions**
  for further axis-by-axis polish. Improve's P4–P5 proposals are
  advisory-only in v1; they print recommendations but do not auto-edit.

If the target has NO harness yet, use `/meta-harness:build` first. If you
just want a one-shot score, use `/meta-harness:evaluate`. Improve is for
the iterative case.

## Arguments

| Argument | Default | Meaning |
|----------|---------|---------|
| `--target <path>` | current working directory | Project root to improve. Same path constraints as build/manage. Symlinks resolved with `pwd -P`. |
| `--auto` | off | Skip the **per-round** approval prompts (treat each as `y`). Does NOT skip the **outer** cwd prompt. Intended for AC-3 testing and rare CI bootstraps. |
| `--max-rounds <n>` | 3 | Override the AC-3 cap. Range `[1, 10]` (integer). Out-of-range values (`0`, negative, `> 10`, non-integer) all exit `IMPROVE_BAD_ARGS`. Production callers should leave this at 3. |
| `--no-apply` | off | Dry-run mode: run the full loop including evaluate + propose + diff display, but skip the apply step. `applied: false` for every round; `exit_reason: dry_run_complete`. |
| `--resume` | off (reserved) | Reserved for v2 (continue from prior `.improve-state.json` without operator confirmation). In v1, specifying `--resume` exits `IMPROVE_BAD_ARGS` — the v1 resume path goes through the interactive Archive/Continue/Quit prompt in `harness-improve` §Round-state initialization. |

`--auto` and `--no-apply` together is legal — useful for "show me what
improve would do, end-to-end, without me clicking through approvals or
writing anything". `--max-rounds 0`, `--max-rounds -3`, `--max-rounds 11`,
`--max-rounds abc`, and `--resume` all exit `IMPROVE_BAD_ARGS`.

## Pre-flight (HR-3) — performed BEFORE any read of the harness

The command enforces the cwd guard up front; the skill re-checks (defense
in depth).

1. Resolve the target. If `--target <path>` is given, use that; otherwise
   use `$PWD`. Resolve symlinks portably with
   `resolved=$(cd "$target" 2>/dev/null && pwd -P)`.
2. Reject and exit `IMPROVE_CWD_REJECTED` if the resolved path is `/`,
   `$HOME` exactly, `/tmp`, `/private/tmp`, non-existent, or a symlink to
   any of those.
3. Show the resolved path and the planned loop bounds, then ask:
   ```
   cwd: <resolved>
   /meta-harness:improve will iterate up to <max_rounds> rounds against
   this directory. Each round may modify files (approval required per
   round; --auto skips per-round prompts but not this one).
   Proceed? [y/N]
   ```
   Default N. If the user answers N → exit `IMPROVE_CWD_REJECTED user_declined_root`.
4. Per-round approval prompts (the SKILL.md §Step 5 gate) are the second
   tier; AC-3 / HR-5 enforce the third tier (the cap + stagnation).

## What this command writes

Two artifacts. Both writes are atomic (`.tmp.$$` → `mv`) and snapshot-backed
where applicable:

1. **`<target>/.meta-harness/.improve-state.json`** — round-state record,
   rewritten after every round. Schema in `skills/harness-improve/SKILL.md`
   §Outputs.
2. **Files changed by each applied proposal** — varies per proposal type
   (P1: full build; P2: single-bucket stub; P3: vendored evaluator
   refresh). Each overwrite is preceded by a snapshot copy under
   `<target>/.meta-harness/.snapshot/<UTC>/`.

`--no-apply` skips artifact 2; artifact 1 is still written (the loop's
audit trail).

## Procedure (delegated)

Once both the cwd guard and the outer prompt pass, this command hands off
to the `harness-improve` skill. The skill is responsible for:

1. Resolve `<plugin_root>` and inputs.
2. Initialize round-state (archive prior `.improve-state.json` if present).
3. Loop:
   a. Step 1 — cap check (AC-3 binding); if exceeded, print "max N rounds reached" and exit.
   b. Step 2 — evaluate (before_score).
   c. Step 3 — manage (healthcheck inputs).
   d. Step 4 — proposer (rule-based catalogue P1–P6).
   e. Step 5 — approval gate (skippable per `--auto`).
   f. Step 6 — atomic apply + snapshot (skipped under `--no-apply`).
   g. Step 7 — re-evaluate (after_score).
   h. Step 8 — record round-state, update stagnation streak, check HR-5.
4. Finalize: write `meta.exit_reason`, summary block on stdout.

See `skills/harness-improve/SKILL.md` for the authoritative procedure
including the proposer catalogue, the stagnation detector subtleties,
and the rollback contract.

## Verification — AC-3 (3-round cap)

```bash
# Bootstrap a fixture (full harness so improve has something to evaluate)
/meta-harness:build --target /tmp/m5-fixture --accept-all

# Run improve with the default cap and auto-approve
/meta-harness:improve --target /tmp/m5-fixture --auto --max-rounds 3 \
  | tee /tmp/m5-improve.log

# AC-3 Check 1: cap message present on stdout
grep -F "max 3 rounds reached" /tmp/m5-improve.log \
  && echo "AC-3 stdout PASS" \
  || { echo "AC-3 stdout FAIL" >&2; exit 1; }

# AC-3 Check 2: state file shows exactly 3 rounds
jq -e '.rounds | length == 3' \
  /tmp/m5-fixture/.meta-harness/.improve-state.json \
  && echo "AC-3 rounds-length PASS" \
  || { echo "AC-3 rounds-length FAIL" >&2; exit 1; }

# AC-3 Check 3: exit_reason is max_rounds_reached
jq -e '.meta.exit_reason == "max_rounds_reached"' \
  /tmp/m5-fixture/.meta-harness/.improve-state.json \
  && echo "AC-3 exit_reason PASS" \
  || { echo "AC-3 exit_reason FAIL" >&2; exit 1; }
```

All three checks must pass for AC-3 PASS. The full procedure also
exercises HR-5 (stagnation auto-exit) via a different fixture; see
SKILL.md §Stagnation auto-exit contract.

## Failure modes (must surface on stderr)

| Code | Meaning |
|------|---------|
| `IMPROVE_CWD_REJECTED` | Pre-flight refused the target (blocked path or not-a-directory), OR the user declined the outer cwd prompt. No reads or writes performed. |
| `IMPROVE_BAD_ARGS` | Contradictory or out-of-range argv. v1-reachable examples: `--max-rounds 0`, `--max-rounds -3` (negative), `--max-rounds 11` (> 10), `--max-rounds abc` (non-integer), `--resume` present (reserved v2). Also any combination involving an unrecognized flag. |
| `IMPROVE_ROUND_FAILED` | An evaluate / manage / apply step failed mid-round. The state file is updated to record the failed round; any partial writes have been rolled back via the snapshot. |
| `IMPROVE_PREEMPTED` | The operator quit at the prior-state choice prompt before any round started. |
| `IMPROVE_STATE_WRITE_FAILED` | Round completed successfully but `.meta-harness/.improve-state.json` atomic write failed. Files applied this round are NOT rolled back (they are real edits); only the audit trail is lost. |

Note: `stagnation_auto_exit`, `max_rounds_reached`, `user_declined`,
`no_proposals_available`, and `dry_run_complete` are NORMAL exit reasons
recorded under `meta.exit_reason`. The process returns 0 in those cases;
they are not failures. `round_apply_failed` is the only `exit_reason` that
correlates with a non-zero exit (via `IMPROVE_ROUND_FAILED`); see
`skills/harness-improve/SKILL.md §exit_reason vocabulary`.

## Examples

```bash
# Interactive improve against the current directory (default 3-round cap).
/meta-harness:improve

# Dry-run: see what improve WOULD do, no writes.
/meta-harness:improve --no-apply

# AC-3 cap exercise: auto-approve all per-round prompts.
/meta-harness:improve --target /tmp/m5-fixture --auto --max-rounds 3

# Diagnostic: extended loop for debugging the proposer catalogue.
/meta-harness:improve --max-rounds 5

# Inspect the round-state of the last run.
jq '.meta, (.rounds | map({round_n, delta, exit: .applied}))' \
  .meta-harness/.improve-state.json
```

## Related

- `skills/harness-improve/SKILL.md` — authoritative procedural workflow,
  including the proposer catalogue (P1–P6), state machine, stagnation
  detector, and rollback contract.
- `commands/evaluate.md` — invoked once per round for scoring.
- `commands/manage.md` — invoked once per round for healthcheck-informed
  proposal selection.
- `commands/build.md` — invoked by the P1 proposal to bootstrap missing
  persona buckets.
- `.shinchan-docs/main-001/adr/ADR-0003-slash-plus-optin-hooks.md` —
  reason hook-based auto-improve is opt-in default-OFF.
