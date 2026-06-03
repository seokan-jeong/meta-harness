---
name: evaluate
description: "Assess how well the current project's Claude Code harness fits the project's actual shape and needs. Runs a strict-superset multi-agent debate panel by default (ADR-0006); --single for one analyzer pass. Returns strict JSON fit findings plus a short human summary."
argument-hint: "[--target <path>] [--json-only] [--raw-out <file>] [--single] [--debate]"
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Task
model: inherit
---

# `/meta-harness:evaluate` — project-fit harness assessment

This is the thin trigger for the harness evaluator. The actual procedure
lives in the `harness-evaluate` skill (`skills/harness-evaluate/SKILL.md`);
this command's only job is to enforce the cwd guard (HR-3), then invoke
the skill.

## When to use this

Run this command when you want a structured fit-assessment for the
harness in your current project — typically:

- After `/meta-harness:build` to confirm the new harness covers what the
  project actually needs.
- Before `/meta-harness:improve` so you have a baseline of findings to
  iterate against.
- When `/meta-harness:manage` reports `drift.drifted == true` and you
  want to see *what* the analyzer thinks has changed.

You can also let an opt-in `Stop` hook call this in the background
(default OFF; see ADR-0003).

## Arguments

| Argument | Default | Meaning |
|----------|---------|---------|
| `--target <path>` | current working directory | Project root to evaluate. Must exist, must be a directory, must NOT be `/`, `$HOME`, or `/tmp`. |
| `--json-only` | off | Suppress the human summary; emit only the strict JSON document. Useful for hook callers and scripted pipelines. **Implies `--single`** unless `--debate` is also passed (scripted callers stay cheap + reproducible). |
| `--raw-out <file>` | (none) | If set, write the strict JSON document to this path atomically (`.tmp` then `mv`), in addition to stdout. |
| `--single` | off (debate is default) | Run **one** analyzer pass instead of the default debate panel — the reproducible, low-cost path (AC-6 is verified on it). Use for CI / golden-file pipelines. Internal callers (`improve`, `build`, the Stop hook) pin it. |
| `--debate` | **on by default** (ADR-0006) | The default behavior since v3.0.0: a strict-superset panel — a single holistic base pass ∪ verified expansion (2 diverse-lens proposers → critic → synthesis) — for higher recall + severity calibration, dispatched as ordinary Task sub-agents. Because it starts from the single pass it **never loses** a `--single` finding. Pass `--debate` explicitly only to force the panel under `--json-only`. `--single --debate` → `EVAL_BAD_ARGS`. If sub-agent dispatch is unavailable, falls back to a single pass with an `EVAL_DEBATE_UNAVAILABLE` notice. |

If no `--target` is given, the current working directory is used.

## What this command produces

Two artifacts on success:

1. A **strict JSON document** matching the schema declared in
   `agents/project-fit-analyzer.md` (Output contract). Validated inline
   by the skill before being shown.
2. A **6–14 line human summary** with `fit_assessment.qualitative`, a
   per-severity finding count, and one line per high-severity finding
   (then medium, then low, capped).

On failure, the command exits non-zero with a short error code on
stderr (`EVAL_CWD_REJECTED`, `EVAL_INVALID_JSON`, etc.). No partial
output.

## Pre-flight (HR-3 cwd guard) — performed BEFORE any LLM call

The command MUST execute this guard before dispatching to the skill.
The skill also re-checks (defense in depth), but this command is the
user-visible gate.

1. Resolve the target path. `--target <path>` if given, else `$PWD`.
   Reject and exit `EVAL_CWD_REJECTED` if the resolved path is `/`,
   `$HOME` exactly, `/tmp` / `/private/tmp`, empty, or a symlink to any
   of those.
2. Print to stdout, before any LLM dispatch:
   ```
   cwd: <resolved absolute path>
   (sketch input: tree + up to 5 top-level config files; denylist applied:
   .env*, id_rsa*, *.pem, *.key, credentials.*, secrets.*)
   ```
3. If `.claude/`, `CLAUDE.md`, `agents/`, and `skills/` are all absent,
   print the warning `"This directory has no harness yet."` and either
   prompt to confirm (interactive) or proceed with the empty-harness
   branch (hook-callable). See `skills/harness-evaluate/SKILL.md` for
   the exact branching.

## Procedure (delegated)

Once the cwd guard passes, this command hands off to the
`harness-evaluate` skill, which:

1. Builds a deterministic `project_sketch` (tree + top-5 configs, with
   ignore-list and HR-4 denylist applied).
2. Collects `harness_state` from the standard harness globs (CLAUDE.md,
   agents/, skills/, commands/, hooks/, .claude/settings.json).
3. Computes the reproducibility pins `project_tree_hash` and
   `harness_state_hash`.
4. Invokes `agents/project-fit-analyzer` via the Task tool with those
   three inputs and the runtime `evaluator_model_id`.
5. Strict-parses + validates the JSON response (retry once on
   malformed, then fail-closed with `EVAL_INVALID_JSON`).
6. Renders pretty-printed JSON + human summary.

See `skills/harness-evaluate/SKILL.md` for the authoritative procedure.

## Failure modes (must surface on stderr)

| Code | Meaning |
|------|---------|
| `EVAL_CWD_REJECTED` | Pre-flight cwd guard refused the target. |
| `EVAL_ANALYZER_MISSING` | `agents/project-fit-analyzer.md` is absent in the plugin install root. |
| `EVAL_INVALID_JSON` | Analyzer returned malformed JSON twice in a row, OR its JSON failed inline validation (including evidence-ref hallucination). |
| `EVAL_DENYLIST_LEAKED` | A denylist-matched file's content appeared in the analyzer's output — emergency abort. |

## Examples

```bash
# Evaluate the current project — runs the debate panel by default.
/meta-harness:evaluate

# One analyzer pass (reproducible / low-cost; for CI / golden files).
/meta-harness:evaluate --single

# Evaluate a different project, capture JSON to disk (debate by default).
/meta-harness:evaluate --target ../other-project --raw-out ./fit-baseline.json

# Hook-friendly: silent JSON-only invocation (implies --single).
/meta-harness:evaluate --json-only

# Force the debate panel even for a scripted/JSON-only run.
/meta-harness:evaluate --json-only --debate
```

## Related

- `agents/project-fit-analyzer.md` — the LLM-as-judge agent definition (output schema lives here).
- `skills/harness-evaluate/SKILL.md` — the procedural workflow.
- `commands/build.md` — bootstraps the harness this evaluator reads.
- `commands/improve.md` — consumes the findings this evaluator produces.
- `ADR-0003` (slash + opt-in hooks).
- `ADR-0005` (the original opt-in `--debate` panel — superseded in part).
- `ADR-0006` (debate by default, strict-superset panel; internal callers pin `--single`).
