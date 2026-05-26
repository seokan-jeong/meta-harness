---
skill_id: harness-improve
name: Harness Improve Workflow
description: "Procedural workflow for /meta-harness:improve. Runs a capped 3-round loop of (evaluate → manage → rule-based propose → user approval → atomic apply + snapshot → re-evaluate → record). Two consecutive non-improvement rounds trigger stagnation auto-exit (HR-5). A 4th round attempt prints 'max 3 rounds reached' and terminates (AC-3)."
invoked_by:
  - commands/improve.md
  - hooks/stop-evaluate.sh (opt-in, default OFF — only if hook is set to chain improve after evaluate)
invokes:
  - skills/harness-evaluate (per-round before/after scoring)
  - skills/harness-manage   (per-round healthcheck for proposal generation)
related_requirements: [FR-3, NFR-1, NFR-4, NFR-5, HR-1, HR-3, HR-4, HR-5, AC-3]
related_adrs: [ADR-0001, ADR-0002, ADR-0003]
---

# Harness Improve — workflow skill

This skill is the **single source of truth** for the `/meta-harness:improve`
procedure. The slash command (`commands/improve.md`) is a thin trigger; this
file owns the state machine, the termination logic, and the round-state
record format.

Improve is the only verb in v1 that **modifies the target harness on disk**.
It does so under three guards:

1. **Per-round user approval** before any apply (NFR-4). `--auto` skips this
   gate; the flag exists primarily so AC-3 (the cap) can be exercised in
   tests without an operator approving four times.
2. **Cap at 3 rounds** (AC-3 / HR-5). A 4th attempt terminates with the
   message `"max 3 rounds reached"`. The cap is configurable via
   `--max-rounds <n>` for diagnostic purposes; production callers should
   leave it at the default.
3. **Stagnation auto-exit** (HR-5). If two consecutive rounds produce a
   non-positive total-score delta, the loop terminates. This protects
   against "the model keeps tweaking but the score isn't moving" loops.

The skill is procedural. It does NOT redefine evaluate's JSON shape,
manage's healthcheck schema, or the 4-bucket model — those live in
`skills/harness-evaluate/SKILL.md`, `skills/harness-manage/SKILL.md`, and
`docs/theory/harness-4-bucket-principles.md` respectively.

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Target project root | `--target <path>` arg, else `$PWD` | Yes |
| Max rounds | `--max-rounds <n>` arg, else 3 | Yes (default) |
| Auto-approve | `--auto` flag | No (off by default) |
| Apply mode | absent `--no-apply` | No (apply on by default; `--no-apply` makes the loop a pure dry-run for diagnostic use) |
| Plugin install root | `$CLAUDE_PLUGIN_ROOT` env var or relative fallback (same pattern as harness-build §Step 1) | Yes |

`--max-rounds 0` is `IMPROVE_BAD_ARGS`. `--max-rounds` greater than `10` is
also `IMPROVE_BAD_ARGS` — improve is an interactive verb, not a long-running
batch job, and double-digit round counts are a misuse signal.

---

## Outputs

1. **Round-state JSON** atomically written at `<target>/.meta-harness/.improve-state.json`
   after every round completes (whether applied, declined, or stagnated).
   Schema:
   ```json
   {
     "schema_version": 1,
     "improve_version": "0.1.0",
     "meta": {
       "target": "/abs/path",
       "started_at": "2026-05-26T09:30:00Z",
       "ended_at": "2026-05-26T09:42:00Z",
       "max_rounds": 3,
       "auto": false,
       "exit_reason": "max_rounds_reached"
     },
     "rounds": [
       {
         "round_n": 1,
         "started_at": "2026-05-26T09:30:00Z",
         "ended_at": "2026-05-26T09:34:00Z",
         "before_score": { "persona": 3, "capabilities": 2, "runtime": 4, "meta_gov": 3, "total": 12 },
         "after_score":  { "persona": 3, "capabilities": 3, "runtime": 4, "meta_gov": 3, "total": 13 },
         "delta": 1,
         "stagnation_streak": 0,
         "proposal_summary": "Add a stub command to commands/ to raise capabilities (lowest axis).",
         "files_changed": ["commands/example.md"],
         "user_approved": true,
         "applied": true,
         "snapshot_path": ".meta-harness/.snapshot/2026-05-26T09-30-00Z/"
       }
     ]
   }
   ```
2. **Human summary** on stdout (one block per round + a final exit block):
   - Round header: `── Round N/M ──`
   - Before score: `before: P/5 C/5 R/5 M/5 = total/20`
   - Proposal: one paragraph (≤6 lines) describing what improve plans to do.
   - Diff: a unified-diff-style preview of the proposed file changes.
   - Approval prompt: `Apply this proposal? [y/N]` (or "auto-applied" if `--auto`).
   - After score (if applied): `after:  P/5 C/5 R/5 M/5 = total/20  (Δ +1)`
   - Stagnation streak: `streak: 0/2 (resets on positive delta)`
   - Final block (after loop exits): one of `EXIT max_rounds_reached`,
     `EXIT stagnation_auto_exit`, `EXIT user_declined`, or `EXIT no_proposals_available`.

The round-state JSON is the authoritative artifact; the human summary is a
convenience. AC-3 verification reads the JSON, not the prose.

### `exit_reason` vocabulary (exhaustive: 5 normal + 1 failure)

| Value | Meaning |
|-------|---------|
| `max_rounds_reached` | The 4th (or `max_rounds + 1`-th) round was attempted; loop terminated at the cap per AC-3. |
| `stagnation_auto_exit` | Two consecutive rounds with `delta ≤ 0`; loop terminated per HR-5. |
| `user_declined` | The user answered N to a per-round approval prompt. |
| `no_proposals_available` | The rule-based proposer produced no proposals at round N (rare; happens when every axis is 5/5 and no lint warnings fire). Counts as a clean exit, not a failure. Because Step 4 returns before Step 8 (the round-state append), the round is NOT recorded in `rounds[]` — `rounds.length` reflects only fully-evaluated rounds. A `no_proposals_available` exit on the very first round therefore produces `rounds: []`. |
| `dry_run_complete` | `--no-apply` was set; the loop ran to completion without writing. `exit_reason` is set to `dry_run_complete` regardless of which natural termination would have fired. |
| `round_apply_failed` | Step 6 (atomic apply) failed mid-batch; the snapshot has been restored. This is the ONLY non-zero-exit `exit_reason` — the process returns via `IMPROVE_ROUND_FAILED` (see §Failure modes). All other values above are normal exits (return 0). The state file still records this value under `meta.exit_reason` for auditability. |

---

## Pre-flight: HR-3 cwd guard

1. Resolve the target. If `--target <path>` is given, use that; otherwise
   use `$PWD`.
2. Resolve symlinks portably with `resolved=$(cd "$target" 2>/dev/null && pwd -P)`.
3. Reject and exit `IMPROVE_CWD_REJECTED` if the resolved path is `/`,
   `$HOME` exactly, `/tmp`, `/private/tmp`, non-existent, or a symlink to
   any of the above.
4. **Confirmation prompt** (unlike manage; unlike evaluate). Improve writes
   to disk; the operator must confirm:
   ```
   cwd: <resolved>
   /meta-harness:improve will iterate up to <max_rounds> rounds of
   (evaluate → propose → apply → re-evaluate) against this directory.
   Each round shows a diff and asks for approval before applying.
   Proceed? [y/N]
   ```
   `--auto` does NOT skip this prompt — only the per-round inner approvals.
   The outer prompt is the HR-3 / AC-8-style cwd gate and is non-negotiable.

If the user declines the outer prompt: exit `IMPROVE_CWD_REJECTED user_declined_root`.

---

## Round-state initialization

After the outer prompt passes:

1. Create (or read) `<target>/.meta-harness/.improve-state.json`. If a prior
   run's state file is present, the operator is offered three choices:
   - `[A]rchive and start fresh` — move the existing file to
     `.meta-harness/.improve-state.json.<UTC>.bak` and start a new run.
     This is the default.
   - `[C]ontinue from prior state` — load `rounds[]`, infer
     `next_round_n = len(rounds) + 1`, retain stagnation streak. Only legal
     if the prior run did NOT reach `max_rounds_reached` or
     `dry_run_complete` (those are terminal). Otherwise → archive forced.
   - `[Q]uit` — exit `IMPROVE_PREEMPTED`.

   **Continuation UX disclosure.** When the prior `exit_reason` is one of
   the resumable terminal states, the Continue prompt MUST surface its
   implication to the operator before they confirm:

   | Prior `exit_reason` | Continuation behavior to surface |
   |---------------------|-----------------------------------|
   | `stagnation_auto_exit` | "Prior run hit stagnation (streak=2). Resume will start with `stagnation_streak=2`; the very next round with delta ≤ 0 will immediately re-fire stagnation_auto_exit. Consider Archive unless you have reason to believe the next round will produce a positive delta." |
   | `user_declined` | "Prior run was declined by the operator at Round N. Resume will re-propose; if the underlying conditions are unchanged, the same proposal may surface again." |
   | `no_proposals_available` | "Prior run had nothing to propose. Resume will re-run evaluate + manage and may still find nothing. This is normal if the harness is fully satisfied." |

   `--auto` defaults to Archive. `--auto --resume` (reserved, not
   implemented v1) would force Continue and bypass the disclosure prompts —
   not desirable in v1 because the resumability subtleties above require
   operator awareness. In v1, `--resume` exits `IMPROVE_BAD_ARGS`.

2. Initialize counters: `next_round_n = 1`, `stagnation_streak = 0`.
3. Record `meta.started_at`.

---

## Per-round procedure (Round N)

Each round executes the following 8 steps. If any step fails, the round is
**rolled back** and the loop terminates with `IMPROVE_ROUND_FAILED`.

### Step 1 — Cap check (AC-3)

```bash
if [ "$next_round_n" -gt "$max_rounds" ]; then
  echo "max ${max_rounds} rounds reached"
  exit_reason="max_rounds_reached"
  goto FINALIZE
fi
```

This is the AC-3 binding. **The check happens at the top of the round,
BEFORE any evaluate/propose/apply work.** A 4th round attempt prints the
literal string `"max 3 rounds reached"` and does NOT execute any apply
step. Verification per AC-3 is `grep -F "max ${max_rounds} rounds reached"`
on stdout, combined with `jq -e '.rounds | length == 3'` on the state
file.

### Step 2 — Before-score (evaluate)

Invoke the harness-evaluate skill against the target. Capture the JSON
result. Extract `total` for the round-state record and the lowest-scoring
axis for the proposer. If evaluate fails (e.g., `EVALUATE_KB_MISSING`),
fail this round → `IMPROVE_ROUND_FAILED`.

### Step 3 — Healthcheck (manage)

Invoke the harness-manage skill against the target (`--json-only`).
Capture `missing_buckets`, `stale_buckets`, and `lint.warnings`. These are
the second set of inputs to the proposer. Manage failure → fail the round
(same rule as Step 2).

### Step 4 — Proposer (rule-based, v1)

The proposer is **rule-based, no LLM call**. It examines the (before_score,
manage_report) pair and selects at most one proposal from a fixed catalogue.
Selection order (first match wins):

| Priority | Trigger | Proposal | File change |
|----------|---------|----------|-------------|
| P1 | `manage.missing_buckets` includes `"persona"` | "Persona bucket is missing — bootstrap CLAUDE.md and vendor the evaluator." | Call `/meta-harness:build --target <target> --accept-all` to scaffold persona bucket (and any other missing buckets in the same pass). |
| P2 | `manage.missing_buckets` includes any of `capabilities`, `runtime`, `meta_gov` | "Bucket `<bucket>` is missing — bootstrap stub files." | Write the bucket-specific stub from `templates/<bucket>/*.tpl` (single-file scope; not a full build). |
| P3 | `kb_diff.drift == true` AND persona present | "Vendored evaluator drifted from current plugin KB — re-vendor `agents/karpathy-evaluator.md`." | Copy `templates/persona/agents/karpathy-evaluator.md.tpl` → `<target>/agents/karpathy-evaluator.md` with current placeholder substitution. |
| P4 | `lint.warnings` contains an L01 (orphan agent reference) | "Skill X references undefined agent Y — propose removing the reference or vendoring the agent." | **Advisory only** — improve does not auto-decide which fix is right; it shows the warning and exits the proposal slot. |
| P5 | Lowest evaluate axis ≤ 2 with a specific KB-3 criterion missing | "Axis `<axis>` scored low because criterion `<id>` is unaddressed — quote the criterion." | **Advisory only** in v1. The auto-fix catalogue does not extend to criterion-specific edits. |
| P6 (none) | All scores ≥ 3 AND no missing buckets AND no lint warnings | — | No proposal generated; round exits with `exit_reason: no_proposals_available`. |

Advisory-only proposals (P4, P5) print the recommendation but do NOT
register any `files_changed`. They still count as a completed round, but
`applied: false` and `delta: 0` (the after_score equals the before_score
because nothing was applied).

**P6 control flow.** When P6 matches, the proposer returns immediately:
set `exit_reason = "no_proposals_available"` and goto FINALIZE. **Step 8 is
NOT executed**, so the round is NOT appended to `rounds[]` — see the
`exit_reason` vocabulary table for the `rounds.length == 0` implication when
P6 fires on the very first round.

### Step 5 — Approval gate (NFR-4)

1. Render the proposal text (≤6 lines).
2. Render the file-change diff (unified diff format). For advisory-only
   proposals, the diff section reads `(no changes — advisory only)`.
3. Prompt: `Apply this proposal? [y/N]`. Default N.
4. `--auto` skips this prompt and treats the answer as `y`.
5. If the user answers N: record `user_approved: false`, `applied: false`,
   set `exit_reason: user_declined`, write round-state, and goto FINALIZE.
   The round counts as completed (it appears in `rounds[]`) but with no
   files changed.

### Step 6 — Atomic apply + snapshot

Only reached if `user_approved: true` and the proposal had file changes
(P1–P3).

1. For each file in `files_changed`:
   - If the file exists, copy it to
     `<target>/.meta-harness/.snapshot/<UTC>/<original-relative-path>`.
   - Atomically write the new content: `<dest>.tmp.$$` → `mv`.
2. Same atomic-write contract as harness-build §Step 4. On any failure
   mid-batch:
   - Restore from snapshot.
   - Mark round as `applied: false`, `delta: 0`, `exit_reason: round_apply_failed`.
   - Exit `IMPROVE_ROUND_FAILED` (different from `IMPROVE_BAD_ARGS` —
     this is a runtime failure of an applied proposal).
3. **Rollback scope (honest disclosure)**: snapshots restore overwritten
   files; they do NOT undo NEW files written this round if a later write
   in the same round failed. (For P1/P2, where improve calls into build,
   build's own rollback contract applies — see `harness-build` §Step 4.3.)
4. **`--no-apply`** mode: Step 6 is skipped entirely. `applied: false`,
   `delta: 0`, snapshot path omitted.

### Step 7 — After-score (re-evaluate)

Only reached if Step 6 actually applied changes (i.e., not `--no-apply`,
not user-declined, not advisory-only). Otherwise `after_score = before_score`
and `delta = 0`.

Invoke harness-evaluate again. Capture the new total. Compute
`delta = after_score.total - before_score.total`.

### Step 8 — Round-state record + stagnation check

1. Update stagnation streak:
   ```
   if delta <= 0: stagnation_streak += 1
   else:          stagnation_streak = 0
   ```
2. Append the round record to `rounds[]` per the schema above.
3. Atomically rewrite `<target>/.meta-harness/.improve-state.json`.
4. Stagnation check (HR-5):
   ```
   if stagnation_streak >= 2:
     exit_reason = "stagnation_auto_exit"
     goto FINALIZE
   ```
5. Otherwise: `next_round_n += 1`, loop back to Step 1.

---

## FINALIZE — write `meta.exit_reason` and emit summary

When the loop exits (Step 1 cap, Step 4 P6, Step 5 user_declined, or Step 8.4
stagnation), control reaches FINALIZE:

1. **`--no-apply` override.** If the run was launched with `--no-apply`, the
   natural `exit_reason` set by the exiting step (one of `max_rounds_reached`,
   `no_proposals_available`, `user_declined`, `stagnation_auto_exit`) is
   **replaced** by `dry_run_complete` here, before the state file is written.
   This is the single override point — no per-step branching in Steps 1/4/5/8.
   `round_apply_failed` is NOT overridden because Step 6 (where it is set) is
   skipped under `--no-apply`, so the case cannot arise. Rationale: dry-run
   mode's natural exits are all spurious-by-design (every delta is 0 under
   `--no-apply` because Step 7 is skipped, so stagnation fires on round 2
   every time) and the user-facing label should reflect the actual mode, not
   the incidental termination.
2. Set `meta.ended_at`.
3. Atomically write the final state file (HR-1).
4. Emit the final stdout block: `EXIT <exit_reason>` + the human summary.
5. Return 0 for the five normal `exit_reason` values (`max_rounds_reached`,
   `stagnation_auto_exit`, `user_declined`, `no_proposals_available`,
   `dry_run_complete`); return `IMPROVE_ROUND_FAILED`'s non-zero code if
   `meta.exit_reason == "round_apply_failed"`. See §Failure modes for the
   exit-code mapping for the four `IMPROVE_*` codes.

---

## Stagnation detector — honest disclosure

The stagnation rule "2 consecutive rounds with `delta ≤ 0`" is intentionally
conservative. Subtleties an operator should know:

- **One bad round alone is not enough.** A single round with `delta = 0`
  (e.g., advisory-only) does NOT trigger stagnation; the streak counter
  starts. Stagnation fires on the *second* consecutive non-positive delta.
- **`delta == 0` counts as non-improvement.** An applied proposal that
  produces no measurable score change is treated as "didn't help" for
  stagnation purposes. This is honest: the evaluator's range form (AC-6,
  max - min ≤ 2) means a 0-delta is within evaluator noise, but improve
  cannot tell signal from noise without multiple samples.
- **The streak resets on the first positive delta.** A +1 in Round 3 after
  two 0s in Rounds 1–2 puts the streak back to 0. This means a single
  meaningful improvement late in the loop is forgiven.
- **The user-declined round does NOT advance the streak** (forward-looking
  for v2). In v1 this is moot because §Step 5.5 always terminates the loop
  on N (goto FINALIZE with `exit_reason: user_declined`) — there is no
  subsequent round to receive the non-incremented streak. The disclosure
  exists so v2 (which may support partial-decline-then-continue) inherits
  a consistent semantic: declined rounds are "no signal", not "no
  improvement". `delta` is undefined for declined rounds and the round
  still appears in `rounds[]` with `applied: false`.

---

## Failure modes

| Code | Meaning | Exit |
|------|---------|------|
| `IMPROVE_CWD_REJECTED` | Pre-flight refused the target, OR the user declined the outer cwd prompt. No reads or writes. | 1 |
| `IMPROVE_BAD_ARGS` | Contradictory or out-of-range argv (`--max-rounds 0`, `--max-rounds > 10`, `--auto` + `--no-apply` is legal, `--auto` + `--resume` is reserved-not-implemented). | 4 |
| `IMPROVE_ROUND_FAILED` | An evaluate / manage / apply step failed mid-round. The state file is updated to record the failed round; snapshots have been restored where possible. | 5 |
| `IMPROVE_PREEMPTED` | The operator quit at the prior-state choice prompt before any round started. | 6 |
| `IMPROVE_STATE_WRITE_FAILED` | Round completed successfully but `.meta-harness/.improve-state.json` atomic write failed. The in-memory state is lost; previously applied file changes are NOT rolled back (they are real edits). | 7 |

Note that `stagnation_auto_exit`, `max_rounds_reached`, `user_declined`,
and `no_proposals_available` are NOT failures — they are normal exit
reasons recorded under `meta.exit_reason` with the process returning 0.

---

## AC-3 contract (binding)

> When `/meta-harness:improve` runs with `--max-rounds 3 --auto` against
> a fixture harness, the loop MUST execute at most 3 apply-eligible rounds.
> A 4th round attempt MUST print `"max 3 rounds reached"` on stdout AND
> set `meta.exit_reason == "max_rounds_reached"` in the state file. The
> state file's `rounds` array MUST have length exactly 3.

Mechanical verification (this is what M5 ships against):

```bash
# fixture with all 4 buckets so improve has something to evaluate
# (typically created by /meta-harness:build --accept-all)

# Run with auto-approve and the default cap
/meta-harness:improve --target /tmp/m5-fixture --auto --max-rounds 3

# Check 1: stdout includes the cap message
last_stdout=$(... captured ...)
echo "$last_stdout" | grep -F "max 3 rounds reached" >/dev/null || exit 1

# Check 2: state file shows exactly 3 rounds + correct exit_reason
jq -e '.rounds | length == 3' /tmp/m5-fixture/.meta-harness/.improve-state.json
jq -e '.meta.exit_reason == "max_rounds_reached"' /tmp/m5-fixture/.meta-harness/.improve-state.json
```

Both `jq -e` invocations must exit 0.

---

## Stagnation auto-exit contract (HR-5)

> When two consecutive rounds produce `delta ≤ 0`, the loop terminates
> immediately. The state file's `meta.exit_reason` MUST be
> `"stagnation_auto_exit"`. The state file's `rounds` array length MUST
> equal the number of rounds actually executed (≤ max_rounds).

This is exercised by a fixture where the proposer's catalogue produces
advisory-only proposals (P4/P5) two rounds in a row. In v1 the simplest
fixture is: start from a fully built harness with no missing buckets,
no drift, and no lint warnings — the proposer hits P6 ("no proposals
available") immediately on Round 1, which is a clean exit, not a
stagnation. To exercise stagnation, the fixture must have one fixable
issue (so Round 1 has a positive delta) followed by two unfixable issues
(advisory-only proposals → delta = 0 twice → stagnation_auto_exit fires
between Round 2 and Round 3).

The proposer is rule-based and deterministic, so stagnation behavior is
reproducible. v2 may introduce LLM-based proposers, at which point the
"deterministic" guarantee will need to be relaxed.

---

## Diff preview format (NFR-4)

For every file change `files_changed[i]`, the approval gate renders a
unified diff:

```
--- a/<path>          (snapshot copy)
+++ b/<path>          (proposed)
@@ -1,3 +1,5 @@
 existing line
+new line
+new line
 existing line
```

For NEW files (no prior snapshot), the diff reads `--- /dev/null` on the
`-` side. For DELETED files (rare; not triggered by any v1 proposal),
the diff reads `+++ /dev/null` on the `+` side. Diff generation uses
`diff -u` (POSIX) on each file pair; no external tooling required.

The diff is for human review only; the actual write uses the new file's
full content, not the diff.

---

## Out of scope for v1

- **LLM-based proposers.** The v1 catalogue (P1–P6) is rule-based and
  deterministic. Adding an LLM proposer (e.g., "the evaluator's rationale
  → propose a specific edit") is a v2 design — it would change the AC-3
  story (non-determinism) and introduce a second LLM call per round.
- **Cross-round memory of declined proposals.** If the operator declines
  the same proposal twice across runs, improve does NOT remember and will
  propose it a third time. v2 may introduce a "muted proposals" list.
- **Multi-file proposals beyond what build supports.** P1 dispatches to
  `/meta-harness:build --accept-all` which handles cross-file atomicity.
  Other proposals are single-file. Multi-file improve-specific edits are
  v2.
- **Concurrent improve runs against the same target.** Not protected by
  a lockfile. Operators should not run two improves against the same
  directory simultaneously.

---

## See also

- `commands/improve.md` — the thin user-facing trigger.
- `skills/harness-evaluate/SKILL.md` — invoked per round for before/after
  scoring.
- `skills/harness-manage/SKILL.md` — invoked per round for healthcheck
  inputs to the proposer.
- `skills/harness-build/SKILL.md` — invoked by the P1 proposal (full
  build to bootstrap a missing persona bucket).
- `docs/theory/harness-4-bucket-principles.md` — the rubric the proposer
  consults when reading evaluate rationales.
- `.shinchan-docs/main-001/adr/ADR-0003-slash-plus-optin-hooks.md` —
  reason `stop-evaluate.sh` is opt-in default-OFF (improve runs are
  user-initiated, not background-triggered).
