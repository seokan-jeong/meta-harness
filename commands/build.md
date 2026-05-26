---
name: build
description: "Bootstrap a complete 4-bucket Claude Code harness (Persona, Capabilities, Runtime, Meta-Governance) into the current project from the bundled meta-harness templates. Surfaces a diff and waits for user approval before any disk write."
argument-hint: "[--target <path>] [--dry-run] [--accept-all]"
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
model: inherit
---

# `/meta-harness:build` — bootstrap a project harness from templates

This is the thin trigger for the harness builder. The actual procedure lives
in the `harness-build` skill (`skills/harness-build/SKILL.md`); this command's
only job is to enforce the cwd guard (HR-3) plus the "treat this directory as
the project root?" confirmation (AC-8), then invoke the skill.

## When to use this

Run this command when you are sitting in a project root that has either no
Claude Code harness yet or only a partial one, and you want to bootstrap the
full 4-bucket layout from `meta-harness` templates. Typical situations:

- A brand-new repo with no `CLAUDE.md`, no `.claude/`, no `skills/`.
- An existing repo where you want to introduce a Claude Code harness for the
  first time — the build skill diffs each target path and prompts before
  overwriting anything that already exists.
- Re-running build after upstream template updates, before the dedicated
  `/meta-harness:manage` re-sync command lands (M4).

If a harness already exists and you want a healthcheck (not a re-bootstrap),
wait for `/meta-harness:manage` (M4) or run `/meta-harness:evaluate` instead.

## Arguments

| Argument | Default | Meaning |
|----------|---------|---------|
| `--target <path>` | current working directory | Project root to write into. Must exist, must be a directory, must NOT be `/`, `$HOME`, `/tmp`, or `/private/tmp`. Symlinks are resolved with `pwd -P` and compared against the reject list. |
| `--dry-run` | off | Run pre-flight, planning, and the diff preview, then exit before any write. Useful to see what `/meta-harness:build` would do without committing. |
| `--accept-all` | off | Skip both confirmation prompts (Step 0 and Step 3 in the skill). Intended for scripted / CI bootstraps. Use with care: this defeats the AC-8 user-approval gate. |

If no `--target` is given, the current working directory is used.

## Pre-flight (HR-3 + AC-8 cwd guard) — performed BEFORE any disk write

The command MUST execute this guard before dispatching to the skill. The skill
also re-checks (defense in depth), but this command is the user-visible gate.

1. Resolve the target. If `--target <path>` is given, use that; otherwise use
   `$PWD`. Resolve symlinks portably with `resolved=$(cd "$target" 2>/dev/null && pwd -P)`
   (POSIX; works on macOS and Linux without GNU `readlink -f`).
2. Reject and exit `BUILD_CWD_REJECTED` if the resolved path is:
   - `/`
   - `$HOME` exactly
   - `/tmp` or `/private/tmp`
   - Non-existent or not a directory
   - A symlink to any of the above
3. Print the resolved cwd, then ask:
   ```
   cwd: <resolved absolute path>
   Treat this directory as the project root? [y/N]
   ```
   Default is **N**. If the user answers `N` (or anything other than `y`/`Y`),
   exit `BUILD_CWD_REJECTED user_declined_root`. `--accept-all` skips this
   prompt (records the bypass on stderr).
4. The Step-3 diff approval prompt is the second gate; see "Procedure" below.

Per AC-8: as long as the user answers N to either Step 0 or Step 3, NO file
is written. All disk writes are confined to Step 4 of the skill.

## What this command writes

On approval, the build skill creates these 9 paths under the target (this is
the AC-1 path set; the build is verified by `find`-ing each one after
writes):

| # | Path | Bucket | Purpose |
|---|------|--------|---------|
| 1 | `CLAUDE.md` | Persona | Project-shaped Claude Code "constitution" with 4-bucket section headers (PER-1, PER-3). |
| 2 | `agents/karpathy-evaluator.md` | Persona | Vendored copy of the harness evaluator agent, pinned to the KB hash at build time (PER-2). |
| 3 | `skills/example-skill/SKILL.md` | Capabilities | Placeholder skill stub demonstrating the shape rewarded by CAP-1 / CAP-2 / CAP-5. |
| 4 | `commands/example-command.md` | Capabilities | Placeholder slash-command stub dispatching to the example skill (CAP-2). |
| 5 | `.claude/settings.json` | Runtime | Conservative tool allow/deny lists; `model: inherit` (RUN-1, RUN-2). |
| 6 | `hooks/example-hook.sh` + `hooks/hooks.json` | Runtime | Sample SessionStart hook, **disabled by default** in the registry (RUN-3). |
| 7 | `README.md` | Meta-Gov | Documents the harness (not just the product), records KB version and manifest hash (MG-1, MG-4). |
| 8 | `CHANGELOG.md` | Meta-Gov | Keep-a-Changelog format, SemVer-tracked harness history (MG-2). |
| 9 | `docs/ADR-0001-static-kb-choice.md` | Meta-Gov | Project-side ADR explaining the static KB choice (MG-3). |

(Path #6 contributes two files but counts as one AC-1 slot — "hooks/* >= 1".)

## Procedure (delegated)

Once the cwd guard passes, this command hands off to the `harness-build` skill.
The skill is responsible for the rest:

1. Resolve template variables (`{{project_name}}`, `{{kb_set_version}}`,
   `{{kb_manifest_hash}}`, `{{generated_at}}`) from `basename`, the plugin's
   `docs/kb-manifest.json`, and `date -u`.
2. Plan the write set: classify each target path as create / skip / conflict.
3. Show the diff and ask `Apply these changes? [y/N]`. AC-8 gate.
4. Atomic write (`.tmp.$$` -> `mv`), with a `.meta-harness/.snapshot/<UTC>/`
   backup before any overwrite. Rollback on any failure.
5. Post-write verification: the 9-path existence check.

See `skills/harness-build/SKILL.md` for the authoritative procedure, including
the exact verification snippet and the rollback contract.

## Failure modes (must surface on stderr)

| Code | Meaning |
|------|---------|
| `BUILD_CWD_REJECTED` | Pre-flight cwd guard refused the target, OR the user answered N to "Treat this directory as the project root?". No files written. |
| `BUILD_USER_DECLINED` | The user answered N to the Step-3 "Apply these changes?" prompt. No files written. |
| `BUILD_WRITE_FAILED` | A file write or rename failed mid-build. Any files already written in this run have been rolled back; overwritten files have been restored from `.meta-harness/.snapshot/`. |
| `BUILD_KB_MISSING` | The plugin's `docs/kb-manifest.json` or one of the KB files it references is missing or empty. The build refuses to proceed because the vendored evaluator needs a real `kb_manifest_hash`. |
| `BUILD_CONFLICT_DECLINED` | The user reviewed conflicts in the diff and chose not to overwrite. Functionally a `BUILD_USER_DECLINED`; emitted as a distinct code so operators can distinguish "decline because of conflicts" from "decline because of cold-feet". |
| `BUILD_VERIFICATION_FAILED` | Step 5 of the skill (9-path existence check) found a missing slot AFTER Step 4 claimed success. Writes from this run remain on disk; inspect `.meta-harness/.snapshot/<UTC>/` and re-run with `--dry-run` to diagnose. |
| `BUILD_BAD_ARGS` | Contradictory argv combination (e.g., `--dry-run --accept-all`, or `--target` pointing at a non-existent path). No files written. |

## Examples

```
# Bootstrap into the current directory after confirming both prompts.
/meta-harness:build

# Bootstrap into a different project root.
/meta-harness:build --target ../my-new-project

# Preview what build would do, without writing anything.
/meta-harness:build --dry-run

# Scripted / CI bootstrap (skips BOTH confirmation prompts — use with care).
/meta-harness:build --accept-all
```

## Related

- `skills/harness-build/SKILL.md` — authoritative procedural workflow,
  including the atomic-write / rollback contract.
- `commands/evaluate.md` — companion command; run after build to score the
  newly bootstrapped harness on the 4-bucket rubric.
- `docs/ADR-0001-static-curated-kb.md` — the upstream ADR. The local mirror
  written into bootstrapped projects lives at
  `templates/meta-gov/docs/ADR-0001-static-kb-choice.md.tpl`.
