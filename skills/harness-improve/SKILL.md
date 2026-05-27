---
skill_id: harness-improve
name: Harness Improve Workflow
description: "Procedural workflow for /meta-harness:improve. Runs a capped 3-round loop of (evaluate → pick top finding → propose patch → user approval → atomic apply + snapshot → re-evaluate → record state). Two consecutive non-improvement rounds trigger stagnation auto-exit (HR-5). A 4th round attempt prints 'max 3 rounds reached' and terminates (AC-3). Replaces the prior rule-based bucket-fix proposer."
invoked_by:
  - commands/improve.md
invokes:
  - skills/harness-evaluate (per-round before/after fit assessment)
related_requirements: [FR-3, NFR-1, NFR-4, NFR-5, HR-1, HR-3, HR-4, HR-5, AC-3]
related_adrs: [ADR-0001, ADR-0002, ADR-0003]
---

# Harness Improve — workflow skill

This skill is the **single source of truth** for the `/meta-harness:improve`
procedure. The slash command (`commands/improve.md`) is a thin trigger;
this file owns the state machine, the termination logic, and the
round-state record format.

Improve is the only verb in v2 that **modifies the target harness on
disk** beyond first-time build. It does so under three guards:

1. **Per-round user approval** before any apply (NFR-4). `--auto` skips
   this gate; the flag exists primarily so AC-3 (the cap) can be exercised
   in tests without an operator approving multiple times.
2. **Cap at 3 rounds** (AC-3 / HR-5). A 4th attempt terminates with the
   literal string `"max 3 rounds reached"`. The cap is configurable via
   `--max-rounds <n>` for diagnostic use; production callers should leave
   it at the default.
3. **Stagnation auto-exit** (HR-5). If two consecutive rounds do not
   reduce the count of *actionable findings* (high + medium severity),
   the loop terminates. This protects against "the model keeps tweaking
   but fit isn't improving" loops.

The skill is procedural. It does NOT redefine evaluate's JSON shape or
the fit-finding model — those live in `skills/harness-evaluate/SKILL.md`
and `agents/project-fit-analyzer.md`.

---

## Inputs

| Input                      | Source                                                                                     | Required |
| -------------------------- | ------------------------------------------------------------------------------------------ | -------- |
| Target project root        | `--target <path>` arg, else `$PWD`                                                         | Yes      |
| Max rounds                 | `--max-rounds <n>` arg, default `3`                                                        | Yes (default) |
| Auto-approve per-round     | `--auto` flag                                                                              | No       |
| Apply mode                 | absent `--no-apply` (apply on by default; `--no-apply` makes the loop a pure dry-run)      | No       |
| Plugin install root        | `$CLAUDE_PLUGIN_ROOT` else relative fallback (same pattern as `harness-build`)             | Yes      |

`--max-rounds 0` is `IMPROVE_BAD_ARGS`. `--max-rounds > 10` is also
`IMPROVE_BAD_ARGS` — improve is an interactive verb, not a long-running
batch job.

There is no KB input. The prior `docs/kb-manifest.json` chain is retired.

---

## Outputs

1. **Round-state JSON** atomically written to
   `<target>/.meta-harness/.improve-state.json` after every round
   completes (whether applied, declined, or stagnated). Schema:

   ```jsonc
   {
     "schema_version": 1,
     "improve_version": "2.0.0",
     "meta": {
       "target": "/abs/path",
       "started_at": "2026-05-27T10:30:00Z",
       "ended_at": "2026-05-27T10:42:00Z",
       "max_rounds": 3,
       "auto": false,
       "exit_reason": "max_rounds_reached"
     },
     "rounds": [
       {
         "round_n": 1,
         "started_at": "2026-05-27T10:30:00Z",
         "ended_at": "2026-05-27T10:34:00Z",
         "before_fit": {
           "qualitative": "decent",
           "findings_total": 4,
           "findings_high": 1,
           "findings_medium": 2,
           "findings_low": 1,
           "actionable": 3
         },
         "after_fit": {
           "qualitative": "good",
           "findings_total": 2,
           "findings_high": 0,
           "findings_medium": 1,
           "findings_low": 1,
           "actionable": 1
         },
         "delta_actionable": -2,
         "stagnation_streak": 0,
         "target_finding": {
           "id": "F-001",
           "category": "coverage-gap",
           "severity": "high",
           "summary": "..."
         },
         "proposal_summary": "Generate skills/feature-scaffold/SKILL.md stub from F-001.",
         "files_changed": ["skills/feature-scaffold/SKILL.md"],
         "user_approved": true,
         "applied": true,
         "snapshot_path": ".meta-harness/.snapshot/2026-05-27T10-30-00Z/"
       }
     ]
   }
   ```

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

### `exit_reason` vocabulary (6 normal + 1 failure)

| Value                       | Meaning                                                                                  |
| --------------------------- | ---------------------------------------------------------------------------------------- |
| `max_rounds_reached`        | The 4th (or `max_rounds + 1`-th) round was attempted; loop terminated per AC-3.          |
| `stagnation_auto_exit`      | Two consecutive rounds with `delta_actionable >= 0`; loop terminated per HR-5.            |
| `user_declined`             | The user answered N to a per-round approval prompt.                                       |
| `no_findings_to_address`    | Round started with `actionable == 0` (no high/medium findings); nothing to do.            |
| `well_aligned`              | Round started with `fit_assessment.qualitative == "well-aligned"`; harness is fit.        |
| `dry_run_complete`          | `--no-apply` was set; the loop ran to completion without writing.                         |
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
3. Record `meta.started_at`.

---

## Per-round procedure (Round N)

Each round executes the following 8 steps. If a step fails, the round is
rolled back and the loop terminates with `IMPROVE_ROUND_FAILED`.

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

Invoke `skills/harness-evaluate` against the target. Capture the JSON
result. Extract:

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
   `snap="$resolved/.meta-harness/.snapshot/$(date -u +%Y%m%dT%H%M%SZ)"`.
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

Invoke `harness-evaluate` again. Capture the new counts. Compute:

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

When the loop exits (Step 1 cap, Step 2 early-exit, Step 5 user_declined,
or Step 8 stagnation):

1. **`--no-apply` override.** If the run was launched with `--no-apply`,
   replace the natural `exit_reason` with `dry_run_complete` before the
   state file is written. Single override point. `round_apply_failed` is
   not overridden because Step 6 (where it is set) is skipped under
   `--no-apply`.
2. Set `meta.ended_at`.
3. Atomically write the final `.improve-state.json` (HR-1).
4. Emit `EXIT <exit_reason>` and the human summary.
5. Return 0 for the six normal reasons; return `IMPROVE_ROUND_FAILED`'s
   non-zero code for `round_apply_failed`.

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

The five normal `exit_reason` values (`max_rounds_reached`,
`stagnation_auto_exit`, `user_declined`, `no_findings_to_address`,
`well_aligned`, `dry_run_complete`) are NOT failures — they return 0.

---

## AC-3 contract (binding, v2 form)

> When `/meta-harness:improve` runs with `--max-rounds 3 --auto` against
> a fixture harness that has at least 3 actionable findings per round
> (sufficient to keep the loop going), the loop MUST execute at most 3
> apply-eligible rounds. A 4th round attempt MUST print
> `"max 3 rounds reached"` on stdout AND set
> `meta.exit_reason == "max_rounds_reached"` in the state file. The
> state file's `rounds` array MUST have length exactly 3.

Mechanical verification:

```bash
# Fixture: a project + harness with enough coverage gaps that proposals
# keep firing for 3 rounds. (Constructed by adding 4+ unrelated TODO
# directories the analyzer flags as coverage-gap.)
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

v2.x may introduce LLM-based proposers, at which point the determinism
guarantee will need to be relaxed.

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

## Out of scope for v2.0

- **LLM-based proposers.** v2.0's catalogue (Step 4 table) is
  rule-based and deterministic. Adding an LLM proposer ("the analyzer's
  rationale → propose a specific edit") would change AC-3's reproducibility
  story.
- **Multi-finding rounds.** One round addresses one finding. Tackling
  several findings per round is v2.x — it would complicate the diff
  preview and the rollback contract.
- **Cross-round memory of declined proposals.** If the operator declines
  the same proposal twice across runs, improve will propose it a third
  time. v2.x may introduce a `.muted_findings` list.
- **Concurrent improve runs against the same target.** Not protected by
  a lockfile.
- **Low-severity auto-fixes.** v2.0 only acts on high + medium findings.
  Low-severity findings surface in the human summary but are not
  proposal-eligible.

---

## See also

- `commands/improve.md` — the thin user-facing trigger.
- `skills/harness-evaluate/SKILL.md` — invoked per round for before/after
  fit assessment.
- `skills/harness-build/SKILL.md` — owns the stub generation templates
  improve reuses for coverage-gap / pain-pattern findings.
- `skills/harness-manage/SKILL.md` — reads the same `state.json` improve
  writes; the two skills agree on drift via shared hash.
- `agents/project-fit-analyzer.md` — produces the findings improve
  consumes.
