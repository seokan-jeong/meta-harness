---
name: manage
description: "Healthcheck a project-level harness: inventory, fit-drift detection between current project state and last-reconciled snapshot, and internal lint. Read-only by default; emits a strict JSON report. Hook-callable."
argument-hint: "[--target <path>] [--json-only] [--silent] [--write-report <path>]"
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
model: inherit
---

# `/meta-harness:manage` — healthcheck a project harness

This is the thin trigger for the manage workflow. The actual procedure
lives in the `harness-manage` skill (`skills/harness-manage/SKILL.md`);
this command's only job is to enforce the cwd guard (HR-3) and dispatch
to the skill. **Manage is read-only by default** — it does not modify
the target. The single optional write is `--write-report <path>` (JSON
report to disk), atomic.

Manage stays LLM-free. If you want analyzer findings, run
`/meta-harness:evaluate`.

## When to use this

- **Routine healthcheck.** A harness has been in use for a few weeks;
  you want to know whether the project has moved since last reconcile
  and whether any harness file has internal inconsistencies.
- **Pre-flight before `/meta-harness:improve`.** Manage's drift bit is
  the cue for "should I run evaluate next?"
- **CI / SessionStart hook.** `hooks/session-start-healthcheck.sh`
  (default OFF per ADR-0003) calls manage with `--json-only --silent`
  and writes the report under `.meta-harness/reports/`.
- **AC-9 verification.** A project without a recorded `state.json`
  (or with a moved tree) MUST surface `drift.drifted == true`. See
  Verification below.

If a harness does NOT yet exist, use `/meta-harness:build`. If you want
analyzer-driven fit findings, use `/meta-harness:evaluate`. Manage
answers the narrower deterministic question: *did the project move,
and do the harness files look internally consistent?*

## Arguments

| Argument | Default | Meaning |
|----------|---------|---------|
| `--target <path>` | current working directory | Project root to inspect. Same path constraints as build/evaluate. |
| `--json-only` | off | Print ONLY the JSON object on stdout. Required for piping to `jq`. |
| `--silent` | off | Suppress stdout entirely. Use with `--write-report`. |
| `--write-report <path>` | off | Atomically write the JSON report to `<path>` (parent dir must exist). |

`--json-only` and `--silent` together is legal.

## Pre-flight (HR-3) — performed BEFORE any read of the harness

1. Resolve the target. `--target <path>` if given, else `$PWD`. Resolve
   symlinks with `resolved=$(cd "$target" 2>/dev/null && pwd -P)`.
2. Reject and exit `MANAGE_CWD_REJECTED` if the resolved path is `/`,
   `$HOME` exactly, `/tmp` / `/private/tmp`, non-existent, not a
   directory, or a symlink to any of those.
3. **No interactive prompt** by design (hook-callable; a prompt would
   break SessionStart).

## What this command emits

The JSON object — printed to stdout (unless `--silent`) and optionally
written to `<path>`:

```json
{
  "schema_version": 1,
  "manage_version": "2.0.0",
  "meta": { "target": "...", "checked_at": "..." },
  "inventory": {
    "has_claude_md": true,
    "skills_count": 3,
    "agents_count": 2,
    "commands_count": 0,
    "hooks_count": 0,
    "harness_files_total": 6
  },
  "drift": {
    "recorded_project_tree_hash": "sha256:...",
    "current_project_tree_hash":  "sha256:...",
    "recorded_at": "...",
    "days_since_record": 7,
    "drifted": true,
    "reason": "tree_hash_diff"
  },
  "lint": {
    "warnings": [
      { "id": "L01", "severity": "warn", "message": "..." }
    ]
  }
}
```

The full schema, the inventory rules, drift detection logic, and lint
catalogue live in `skills/harness-manage/SKILL.md`. `lint.warnings`
is an inclusive container — `severity: "info"` entries appear there
alongside `warn`. Valid severities in v2 are `{"warn", "info"}`;
`"error"` is intentionally excluded so the JSON output stays parseable
for AC-9 verification.

## Procedure (delegated)

Once the cwd guard passes, this command hands off to the
`harness-manage` skill:

1. Enumerate harness inventory (CLAUDE.md + agents/ + skills/ +
   commands/ + hooks/), HR-4 denylist applied.
2. Read recorded state from `<target>/.meta-harness/state.json`. If
   absent → `drift.reason = "no_record"`, `drifted = true`.
3. Compute current `project_tree_hash` using the same algorithm as
   `evaluate` Step 1. Compare against recorded.
4. Run five lint rules (L01–L05) — warnings only, never blocking.
5. Render JSON (and optional human summary).
6. Optional atomic write of the report.

See `skills/harness-manage/SKILL.md` for the authoritative procedure
and AC-9 contract.

## Verification — AC-9 (drift detection)

```bash
# Fixture A: a project with no recorded state.
rm -rf /tmp/m4-fixture && mkdir -p /tmp/m4-fixture/{src,agents,skills/x}
printf 'export const a = 1;\n' > /tmp/m4-fixture/src/index.ts
printf '# Fixture\n' > /tmp/m4-fixture/CLAUDE.md

# Run manage and assert drift is true (no record).
/meta-harness:manage --target /tmp/m4-fixture --json-only \
  | jq -e '.drift.drifted == true and .drift.reason == "no_record"' >/dev/null \
  && echo "AC-9 PASS" || { echo "AC-9 FAIL" >&2; exit 1; }
```

Symmetric fixtures for `tree_hash_diff` and `record_corrupt` exist in
the skill's §AC-9 contract section.

## Failure modes (must surface on stderr)

| Code | Meaning |
|------|---------|
| `MANAGE_CWD_REJECTED` | Pre-flight refused the target. |
| `MANAGE_REPORT_WRITE_FAILED` | `--write-report <path>` was given but the atomic write failed. JSON already on stdout (if not `--silent`). |
| `MANAGE_BAD_ARGS` | Contradictory or malformed argv. |

Manage does NOT emit a failure code for "lint warnings present" or "drift
detected" — those are data on the happy path. A hook-callable healthcheck
that exited non-zero on either would spam SessionStart errors.

## Examples

```bash
# Interactive healthcheck of the current directory.
/meta-harness:manage

# JSON-only output, for piping to jq.
/meta-harness:manage --json-only | jq '.drift'

# Hook-style: silent, write report to disk.
/meta-harness:manage --target . --json-only --silent \
  --write-report ".meta-harness/reports/$(date -u +%Y%m%dT%H%M%SZ)-manage.json"
```

## Related

- `skills/harness-manage/SKILL.md` — authoritative procedural workflow.
- `skills/harness-evaluate/SKILL.md` — sibling skill that uses the same
  `project_tree_hash` algorithm.
- `commands/evaluate.md` — run when manage reports `drift.drifted == true`
  to see the actual fit findings.
- `commands/build.md` — writes the `state.json` manage reads.
- `commands/improve.md` — also writes `state.json` after each applied round.
