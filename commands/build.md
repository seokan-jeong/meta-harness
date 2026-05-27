---
name: build
description: "Scaffold a project-tailored Claude Code harness into the current project. Composes a minimal core (CLAUDE.md + project-fit-analyzer copy), optionally invokes the analyzer to discover coverage gaps, generates project-specific stubs per finding, then surfaces a diff and waits for user approval before any disk write."
argument-hint: "[--target <path>] [--dry-run] [--accept-all] [--no-analyzer]"
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Task
model: inherit
---

# `/meta-harness:build` — bootstrap a project-tailored harness

This is the thin trigger for the harness builder. The actual procedure
lives in the `harness-build` skill (`skills/harness-build/SKILL.md`);
this command enforces the cwd guard (HR-3) plus the "treat this
directory as the project root?" confirmation (AC-8), then invokes the
skill.

The build is **project-tailored**, not a fixed template dump. The shape
of what gets written depends on the project's actual shape — a Node
project with React gets different stubs than a Dart project with
`lib/features/`. The standard is the project itself.

## When to use this

- A brand-new repo with no `CLAUDE.md`, no `.claude/`, no `skills/` —
  bootstrap a starter harness shaped by the project's existing code.
- An existing repo where you want to introduce a Claude Code harness for
  the first time — build diffs each target path and prompts before
  overwriting.
- After a major project shape change (new framework, new module layout)
  — re-run build to extend the existing harness with newly-needed stubs.

If a harness already exists and you want a fit-assessment (not a
re-bootstrap), use `/meta-harness:evaluate`. If you want a drift
healthcheck, use `/meta-harness:manage`.

## Arguments

| Argument | Default | Meaning |
|----------|---------|---------|
| `--target <path>` | current working directory | Project root to write into. Must exist, must be a directory, must NOT be `/`, `$HOME`, `/tmp`, or `/private/tmp`. Symlinks resolved with `pwd -P`. |
| `--dry-run` | off | Run pre-flight, planning, analyzer invocation, and the diff preview, then exit before any write. |
| `--accept-all` | off | Skip both confirmation prompts. Intended for scripted / CI bootstraps. Defeats AC-8. |
| `--no-analyzer` | off | Skip the analyzer-driven gap-discovery step. Writes only the 3-file core scaffold; no stubs. Useful for fast offline bootstraps. |

If no `--target` is given, the current working directory is used.

## Pre-flight (HR-3 + AC-8 cwd guard) — performed BEFORE any disk write

1. Resolve the target. `--target <path>` if given, else `$PWD`. Resolve
   symlinks portably with
   `resolved=$(cd "$target" 2>/dev/null && pwd -P)`.
2. Reject and exit `BUILD_CWD_REJECTED` if the resolved path is `/`,
   `$HOME` exactly, `/tmp` / `/private/tmp`, non-existent, not a
   directory, or a symlink to any of the above.
3. Print the resolved cwd, then ask:
   ```
   cwd: <resolved absolute path>
   Treat this directory as the project root? [y/N]
   ```
   Default **N**. `N` → exit `BUILD_CWD_REJECTED user_declined_root`.
   `--accept-all` skips this prompt (records the bypass on stderr).
4. The Step-6 diff approval prompt is the second AC-8 gate; see the
   skill.

Per AC-8: as long as the user answers N to either gate, NO file is
written. All disk writes are confined to Step 7 of the skill.

## What this command writes

The output set is **project-derived**, not fixed. It always contains a
3-file **core**:

| Path | Source | Purpose |
|------|--------|---------|
| `CLAUDE.md` | `templates/persona/CLAUDE.md.tpl` (with placeholders) | Project-shaped instruction file. |
| `.claude/agents/project-fit-analyzer.md` | Verbatim copy of plugin's analyzer | Claude-Code-canonical agent location; the runtime auto-loads it so the project can both self-evaluate and use the analyzer directly. |
| `.meta-harness/.gitignore` | `templates/meta-gov/.meta-harness/.gitignore.tpl` | Keeps snapshot dirs out of git. |

Additionally, for each actionable analyzer finding (high or medium
coverage-gap / pain-pattern) the build proposes a single stub in the
Claude-Code-canonical location:

- `.claude/skills/<slug>/SKILL.md` (skill-shaped finding), or
- `.claude/agents/<slug>.md` (agent-shaped finding).

The stub is a placeholder the operator fills in. The build does NOT
generate full skill bodies — that's `harness-improve`'s job once the
operator has reviewed the stub.

The complete write plan is shown in a diff before any write, per AC-8.

## Procedure (delegated)

Once the cwd guard passes, this command hands off to the `harness-build`
skill. The skill:

1. Builds the same `project_sketch` `evaluate` uses (tree + top-5
   configs, HR-4 denylist applied).
2. Composes the 3-file core scaffold.
3. (Unless `--no-analyzer`) invokes `agents/project-fit-analyzer` with
   the project sketch + proposed core as harness_state, capturing
   coverage-gap and pain-pattern findings.
4. Translates each actionable finding into a stub write entry (slug
   derived from `suggested_action`).
5. Classifies each write entry create / skip / conflict.
6. Shows the diff and asks `Apply these changes? [y/N]`. AC-8 gate.
7. Atomic write (`.tmp.$$` → `mv`), with snapshot backup before
   overwrites. Rollback on any failure.
8. Post-write verification: journal-based existence check, placeholder
   leak check, analyzer-copy sha256 check.

See `skills/harness-build/SKILL.md` for the authoritative procedure
including the rollback contract.

## Failure modes (must surface on stderr)

| Code | Meaning |
|------|---------|
| `BUILD_CWD_REJECTED` | Pre-flight cwd guard refused the target, or the user answered N to "Treat this directory as the project root?". |
| `BUILD_USER_DECLINED` | The user answered N to the apply-diff prompt. No files written. |
| `BUILD_CONFLICT_DECLINED` | Decline at the apply prompt when conflicts were present in the set. |
| `BUILD_WRITE_FAILED` | A write or rename failed mid-build. Files written this run rolled back; overwrites restored from snapshot. |
| `BUILD_ANALYZER_MISSING` | `agents/project-fit-analyzer.md` is absent in the plugin install root. |
| `BUILD_TEMPLATE_MISSING <path>` | A required skeleton template is absent. |
| `BUILD_VERIFICATION_FAILED` | Post-write existence check failed after writes claimed success. |
| `BUILD_PLACEHOLDER_LEAK` | A written file still contains unresolved `{{...}}` markers. |
| `BUILD_ANALYZER_COPY_DRIFT` | The copied analyzer file's sha256 doesn't match the plugin source. |
| `BUILD_BAD_ARGS` | Contradictory argv (e.g., `--dry-run --accept-all`). |

## Examples

```bash
# Bootstrap into the current directory after confirming both prompts.
/meta-harness:build

# Bootstrap into a different project root.
/meta-harness:build --target ../my-new-project

# Preview what build would do, without writing anything.
/meta-harness:build --dry-run

# Fast core-only scaffold; skip the analyzer call.
/meta-harness:build --no-analyzer

# Scripted / CI bootstrap (skips BOTH confirmation prompts — use with care).
/meta-harness:build --accept-all
```

## Related

- `skills/harness-build/SKILL.md` — authoritative procedural workflow.
- `agents/project-fit-analyzer.md` — invoked to discover coverage gaps.
- `commands/evaluate.md` — companion command; run after build to verify fit.
- `commands/improve.md` — consumes the stubs build generates and fleshes them out.
