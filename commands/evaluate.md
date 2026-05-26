---
name: evaluate
description: "Score the current project's Claude Code harness on 4 axes (Persona, Capabilities, Runtime, Meta-Governance) using the bundled KB rubric and the karpathy-evaluator agent. Returns strict JSON plus a short human summary."
argument-hint: "[--target <path>] [--json-only] [--raw-out <file>]"
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Task
model: inherit
---

# `/meta-harness:evaluate` — Karpathy-grade harness scoring

This is the thin trigger for the harness evaluator. The actual procedure lives
in the `harness-evaluate` skill (`skills/harness-evaluate/SKILL.md`); this
command's only job is to enforce the cwd guard (HR-3), then invoke the skill.

## When to use this

Run this command when you want a structured score for the harness in your
current project — typically:

- After `/meta-harness:build` to confirm the new harness is well-formed.
- Before `/meta-harness:improve` so you have a baseline to compare against.
- As an audit step when you suspect harness drift.

You can also let an opt-in `Stop` hook call this in the background (default
OFF; see ADR-0003).

## Arguments

| Argument | Default | Meaning |
|----------|---------|---------|
| `--target <path>` | current working directory | Project root to evaluate. Must exist, must be a directory, must NOT be `/`, `$HOME`, or `/tmp`. |
| `--json-only` | off | Suppress the human summary; emit only the strict JSON document. Useful for hook callers and scripted pipelines. |
| `--raw-out <file>` | (none) | If set, write the strict JSON document to this path atomically (write `.tmp`, then `mv`), in addition to stdout. |

If no `--target` is given, the current working directory is used.

## What this command produces

Exactly two artifacts on success:

1. A **strict JSON document** matching the schema declared in
   `agents/karpathy-evaluator.md` (Output contract section).
   Validated by `scripts/validate-eval-output.sh` before being shown to the user.
2. A **6–12 line human summary** with the per-axis score, the total, and one
   line per axis distilled from the rationale.

On failure, the command exits non-zero with a short error code on stderr
(`EVAL_CWD_REJECTED`, `EVAL_KB_MISSING`, `EVAL_INVALID_JSON`, etc.). No
partial output is written.

## Pre-flight (HR-3 cwd guard) — performed BEFORE any LLM call

The command MUST execute this guard before dispatching to the skill. The skill
also re-checks (defense in depth), but this command is the user-visible
gate.

1. Resolve the target path. If `--target <path>` is given, use that. Otherwise
   use `$PWD`. Reject and exit `EVAL_CWD_REJECTED` if the resolved path is:
   - `/`
   - `$HOME` exactly
   - `/tmp` or `/private/tmp`
   - Empty / cannot be `cd`'d into
   - Symbolic link to any of the above
2. Print to stdout, before any LLM dispatch:
   ```
   cwd: <resolved absolute path>
   harness file candidates:
     - CLAUDE.md
     - agents/*.md
     - skills/**/SKILL.md
     - commands/*.md
     - .claude/settings.json
     - hooks/*
     - README.md
     - CHANGELOG.md
     - docs/ADR-*.md
   (denylist applied: .env*, id_rsa*, *.pem, *.key, credentials.*, secrets.*)
   ```
3. If `.claude/` is absent AND `CLAUDE.md` is absent AND no `agents/` or
   `skills/` directories exist, print the warning `"This directory does not
   look like a Claude Code project root."` and ask the user to confirm before
   proceeding. (Interactive prompt — when called via hook, the hook MUST
   fail-closed instead per ADR-0003.)

If any of (1)/(3) is violated, do NOT call the evaluator. The cwd guard is
the first safety boundary.

## Procedure (delegated)

Once the cwd guard passes, this command hands off to the `harness-evaluate`
skill. The skill is responsible for the rest:

1. Enumerate harness files under the target path.
2. Apply the secret denylist (HR-4 / AC-7).
3. Resolve the KB manifest hash (compute real sha256s if the manifest still
   has placeholders; see `scripts/build-kb-manifest.sh`).
4. Invoke `agents/karpathy-evaluator` via the Task tool (or the plugin runtime's
   equivalent sub-agent dispatcher if `Task` is not available in this slash
   command context), passing the filtered file list, the 3 KB files' content,
   `kb_manifest_hash`, and the runtime `evaluator_model_id`.
5. Strict-parse the JSON response. Validate against the output contract
   (`scripts/validate-eval-output.sh`). On first failure, retry the evaluator
   once (N=1 retry policy per agent's "Execution settings" section); on
   second failure, fail-closed with `EVAL_INVALID_JSON`.
6. Render: pretty-printed JSON + 6–12 line human summary.

See `skills/harness-evaluate/SKILL.md` for the authoritative procedure.

## Failure modes (must surface on stderr)

| Code | Meaning |
|------|---------|
| `EVAL_CWD_REJECTED` | Pre-flight cwd guard refused the target. |
| `EVAL_KB_MISSING` | One or more `docs/theory/*.md` KB files are absent or empty. Evaluator fail-closes per FR-4. |
| `EVAL_INVALID_JSON` | Evaluator returned malformed JSON twice in a row, OR its JSON failed the validator. |
| `EVAL_DENYLIST_LEAKED` | A denylist-matched file's content appeared in the evaluator's output — emergency abort. |

## Examples

```
# Evaluate the current project.
/meta-harness:evaluate

# Evaluate a different project, capture JSON to disk for later diffing.
/meta-harness:evaluate --target ../other-project --raw-out ./eval-baseline.json

# Hook-friendly: silent JSON-only invocation.
/meta-harness:evaluate --json-only
```

## Related

- `agents/karpathy-evaluator.md` — the LLM-as-judge agent definition (output schema lives here).
- `skills/harness-evaluate/SKILL.md` — the procedural workflow.
- `docs/theory/harness-4-bucket-principles.md` — master rubric (KB-3), 20 criteria.
- `docs/kb-manifest.json` — KB hash ledger (HR-2).
- ADR-0002 (single evaluator agent), ADR-0003 (slash + opt-in hooks).
