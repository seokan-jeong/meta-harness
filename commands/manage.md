---
name: manage
description: "Healthcheck a project-level harness: 4-bucket presence, KB drift detection against the plugin manifest, and internal lint. Read-only by default; emits a strict JSON report whose schema is bound to AC-9."
argument-hint: "[--target <path>] [--json-only] [--silent] [--write-report <path>]"
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
model: inherit
---

# `/meta-harness:manage` — healthcheck a project harness

This is the thin trigger for the manage workflow. The actual procedure lives
in the `harness-manage` skill (`skills/harness-manage/SKILL.md`); this
command's only job is to enforce the cwd guard (HR-3) and dispatch to the
skill. **Manage is read-only by default** — it does not modify the target
harness. The single optional write is `--write-report <path>` (JSON report
to disk), which uses the same atomic-write pattern as
`/meta-harness:build`.

## When to use this

Run manage against an existing project harness when you want a structured
healthcheck without re-evaluating the harness's quality score. Typical
situations:

- **Routine healthcheck.** A harness has been in use for a few weeks; you
  want to know which buckets are still intact, whether the vendored KB
  has drifted from the plugin's current KB, and whether any lint rules
  are firing.
- **Pre-flight before `/meta-harness:improve`.** Improve only operates on
  what is actually present; running manage first surfaces missing buckets
  (which improve will not synthesize from nothing — that's `build`'s job).
- **CI / SessionStart hook.** `hooks/session-start-healthcheck.sh` (M6,
  default OFF per ADR-0003) calls manage with `--json-only --silent` and
  writes the report under `.meta-harness/reports/`.
- **AC-9 verification.** A fixture harness with `agents/` removed is the
  AC-9 test rig — manage on that fixture must emit
  `"persona"` in `healthcheck.missing_buckets` (see Verification below).

If a harness does NOT yet exist, use `/meta-harness:build`. If you want a
0–20 quality score, use `/meta-harness:evaluate`. Manage answers the
narrower question "is this harness structurally intact and KB-current?".

## Arguments

| Argument | Default | Meaning |
|----------|---------|---------|
| `--target <path>` | current working directory | Project root to inspect. Must exist, must be a directory, must NOT be `/`, `$HOME`, `/tmp`, or `/private/tmp`. Symlinks resolved with `pwd -P` and compared against the reject list. |
| `--json-only` | off | Print ONLY the JSON object on stdout. Suppress the human summary. Required for piping to `jq` in AC-9-style verifications. |
| `--silent` | off | Suppress stdout entirely. Use with `--write-report` so that hooks running in the background do not spam terminal output. |
| `--write-report <path>` | off | Atomically write the JSON report to `<path>` (parent directory must exist). Failure to write does NOT suppress stdout. |

`--json-only` and `--silent` together is legal: nothing prints, but
`--write-report` still produces the file. `--json-only` and `--interactive`
(reserved, not implemented in v1) is `MANAGE_BAD_ARGS`.

## Pre-flight (HR-3) — performed BEFORE any read of the harness

The command enforces the cwd guard up front; the skill re-checks (defense
in depth).

1. Resolve the target. If `--target <path>` is given, use that; otherwise
   use `$PWD`. Resolve symlinks portably with
   `resolved=$(cd "$target" 2>/dev/null && pwd -P)`.
2. Reject and exit `MANAGE_CWD_REJECTED` if the resolved path is:
   - `/`
   - `$HOME` exactly
   - `/tmp` or `/private/tmp`
   - Non-existent or not a directory
   - A symlink to any of the above
3. **No interactive prompt** by design (manage is hook-callable; a prompt
   would break SessionStart). The cwd guard is the entire pre-flight.

## What this command emits

The JSON object — printed to stdout (unless `--silent`) and optionally
written to `<path>` (when `--write-report` is given):

```json
{
  "schema_version": 1,
  "manage_version": "0.1.0",
  "meta": { "target": "...", "checked_at": "...", "plugin_root": "..." },
  "healthcheck": {
    "present_buckets": ["..."],
    "missing_buckets": ["..."],
    "stale_buckets": ["..."]
  },
  "kb_diff": {
    "project_kb_manifest_hash": "sha256:...",
    "plugin_kb_manifest_hash": "sha256:...",
    "project_kb_set_version": "0.1.0",
    "plugin_kb_set_version": "0.1.0",
    "vendored_at": "...",
    "drift": false
  },
  "lint": {
    "warnings": [
      { "id": "L01", "severity": "warn", "message": "..." },
      { "id": "L02", "severity": "info", "message": "..." }
    ]
  }
}
```

The `*_buckets` arrays use exactly four strings: `"persona"`,
`"capabilities"`, `"runtime"`, `"meta_gov"`. The full schema, the bucket
existence rules, and the lint catalogue live in
`skills/harness-manage/SKILL.md` — this command does not duplicate them.
Note: `lint.warnings` is an **inclusive container** — entries with
`severity: "info"` also appear there (v1 historical name; renamed to
`lint.findings` in v1.1). Valid severities in v1 are `{"warn", "info"}`
only; `"error"` is excluded so the JSON output is always parseable for
AC-9 verification.

## Procedure (delegated)

Once the cwd guard passes, this command hands off to the `harness-manage`
skill. The skill is responsible for the rest:

1. Resolve `<plugin_root>` (env `$CLAUDE_PLUGIN_ROOT` or relative fallback).
2. Read the plugin's `docs/kb-manifest.json`; fail-closed with
   `MANAGE_KB_MISSING` if absent or empty.
3. Enumerate the 4 buckets per the existence rules in SKILL.md §Step 1.
4. Compute KB drift from the project's vendored evaluator frontmatter
   versus the plugin's manifest (SKILL.md §Step 2).
5. Run the four lint rules (L01–L04, SKILL.md §Step 3) — warnings only,
   never blocking.
6. Render JSON (and optional human summary) per SKILL.md §Step 4.
7. Optional atomic write of the report.

See `skills/harness-manage/SKILL.md` for the authoritative procedure,
including the bucket existence rules and the AC-9 contract.

## Verification — AC-9 (F1 disposition, formally registered in REQUESTS.md §6)

```bash
# Build a fixture with agents/ intentionally absent.
rm -rf /tmp/m4-fixture && mkdir -p /tmp/m4-fixture/{skills/x,commands,hooks,.claude}
printf '# Fixture\n' > /tmp/m4-fixture/CLAUDE.md
printf '# fixture skill\n' > /tmp/m4-fixture/skills/x/SKILL.md
printf '# fixture command\n' > /tmp/m4-fixture/commands/x.md
printf '{}\n' > /tmp/m4-fixture/.claude/settings.json
printf '# Fixture\n' > /tmp/m4-fixture/README.md
printf '# Changelog\n' > /tmp/m4-fixture/CHANGELOG.md

# Run manage and assert persona is missing.
/meta-harness:manage --target /tmp/m4-fixture --json-only \
  | jq -e '.healthcheck.missing_buckets | index("persona")' >/dev/null \
  && echo "AC-9 PASS" || { echo "AC-9 FAIL" >&2; exit 1; }
```

The same pattern with `commands/*.md` removed asserts `"capabilities"` in
missing; `.claude/settings.json` removed asserts `"runtime"`; `README.md`
removed asserts `"meta_gov"`. All four are bound to the same JSON schema,
so a single test harness exercises the contract surface.

## Failure modes (must surface on stderr)

| Code | Meaning |
|------|---------|
| `MANAGE_CWD_REJECTED` | Pre-flight refused the target (blocked path or not-a-directory). No reads of harness contents performed. |
| `MANAGE_KB_MISSING` | The plugin's `docs/kb-manifest.json` is absent or empty. Manage refuses to proceed because emitting `drift: false` without a manifest to compare against would be a silent lie. |
| `MANAGE_REPORT_WRITE_FAILED` | `--write-report <path>` was given but the atomic write failed. The JSON has still been printed to stdout (if not `--silent`); only the side-effect file is missing. |
| `MANAGE_BAD_ARGS` | Contradictory or malformed argv. v1-reachable examples: `--write-report` with no value, `--write-report <path>` whose parent directory does not exist, or `--write-report ""`. (Also fires if `--json-only` is paired with the reserved `--interactive` flag, but `--interactive` itself is not implemented in v1.) |

Manage does NOT emit a failure code for "lint warnings present" — warnings
are data on the happy path. A hook-callable healthcheck must not fail on
stylistic findings.

## Examples

```bash
# Interactive healthcheck of the current directory.
/meta-harness:manage

# JSON-only output, for piping to jq.
/meta-harness:manage --json-only \
  | jq '.healthcheck'

# AC-9 verification on a fixture harness.
/meta-harness:manage --target /tmp/m4-fixture --json-only \
  | jq -e '.healthcheck.missing_buckets | index("persona")'

# Hook-style: silent, write report to disk.
/meta-harness:manage --target . --json-only --silent \
  --write-report ".meta-harness/reports/$(date -u +%Y%m%dT%H%M%SZ)-manage.json"
```

## Related

- `skills/harness-manage/SKILL.md` — authoritative procedural workflow,
  including bucket existence rules, KB diff logic, and lint catalogue.
- `commands/build.md` — companion command; manage is the "after build"
  healthcheck and shares the cwd guard + atomic write pattern.
- `commands/evaluate.md` — orthogonal command; evaluate gives a 0–20 score,
  manage gives a structural healthcheck. Run both for a full picture.
- `commands/improve.md` (M5, future) — manage's output is one of improve's
  inputs.
