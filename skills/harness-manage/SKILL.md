---
skill_id: harness-manage
name: Harness Manage Workflow
description: "Procedural workflow for /meta-harness:manage. Detects fit drift between the project's current state and the last-reconciled snapshot, runs deterministic lint over the harness files, and emits a strict JSON healthcheck report. Read-only by default; designed for hook-callable use. Replaces the prior 4-bucket presence + KB-drift checks."
invoked_by:
  - commands/manage.md
  - hooks/session-start-healthcheck.sh (opt-in, default OFF — see ADR-0003)
invokes: []
related_requirements: [FR-2, NFR-1, NFR-3, NFR-4, NFR-5, HR-1, HR-3, HR-4, AC-9]
related_adrs: [ADR-0001, ADR-0003]
---

# Harness Manage — workflow skill

This skill is the **single source of truth** for the `/meta-harness:manage`
procedure. Both the slash command (`commands/manage.md`) and the optional
SessionStart hook follow this skill verbatim.

`manage` is **read-only by default**. Its job is to produce a structured
healthcheck report — *has the project moved since the harness was last
reconciled?* and *do the harness files have internal inconsistencies?* —
without invoking an LLM. Evaluate already calls the analyzer; manage stays
deterministic so it can run on every session start without latency or
token cost.

The skill is procedural. It does NOT score the harness — that is
`/meta-harness:evaluate`'s job. It does NOT propose patches — that is
`/meta-harness:improve`'s job. It produces signals that those two consume.

---

## Inputs

| Input                          | Source                                                                              | Required |
| ------------------------------ | ----------------------------------------------------------------------------------- | -------- |
| Target project root            | `--target <path>` arg, else `$PWD`                                                  | Yes      |
| Recorded state                 | `<target>/.meta-harness/state.json` (written by `build`/`improve`)                  | No (its absence is a finding) |
| `--write-report <path>` arg    | argv                                                                                | No       |
| `--json-only` flag             | argv                                                                                | No       |
| `--silent` flag                | argv (for hook use; suppresses stdout entirely when set with `--write-report`)      | No       |

There is no KB input. The prior `docs/kb-manifest.json` and the
`agents/karpathy-evaluator.md`-frontmatter KB hash chain are retired.

---

## Outputs

1. **Strict JSON** matching the schema below. Primary artifact;
   `--json-only` callers and AC-9 verification depend on it parsing cleanly.
2. **Human summary** (6–14 lines) on stdout when `--json-only` is NOT set:
   - Line 1: `target: <resolved-path>`
   - Line 2: `harness inventory: <N> files (<S> skills, <A> agents, <C> commands)`
   - Line 3: `fit drift: <yes/no> — recorded <recorded[:12]>, current <current[:12]>`
   - Line 4: `recorded at: <ISO-8601 or "never">` and `days since record: <N or "n/a">`
   - Line 5: `lint warnings: <count>`
   - Lines 6–14 (optional): one line per warning, indented two spaces.

### JSON output schema

```json
{
  "schema_version": 1,
  "manage_version": "2.0.0",
  "meta": {
    "target": "/abs/path",
    "checked_at": "2026-05-27T10:30:00Z"
  },
  "inventory": {
    "has_claude_md": true,
    "has_agents_md": false,
    "skills_count": 3,
    "agents_count": 2,
    "commands_count": 0,
    "hooks_count": 0,
    "harness_files_total": 6
  },
  "drift": {
    "recorded_project_tree_hash": "sha256:abc...",
    "current_project_tree_hash":  "sha256:def...",
    "recorded_at": "2026-05-20T08:50:00Z",
    "days_since_record": 7,
    "drifted": true,
    "reason": "tree_hash_diff"
  },
  "lint": {
    "warnings": [
      { "id": "L01", "severity": "warn", "message": "skills/foo/SKILL.md references skills/bar/SKILL.md which does not exist." },
      { "id": "L02", "severity": "info", "message": "agents/baz.md invokes 'qux' agent which is not defined under agents/." }
    ]
  }
}
```

`drift.reason` is one of:

- `"no_record"` — `.meta-harness/state.json` is absent.
- `"tree_hash_diff"` — recorded and current `project_tree_hash` differ.
- `"none"` — recorded equals current. `drifted: false`.
- `"record_corrupt"` — `state.json` exists but isn't parseable JSON / lacks required fields. Treated as `drifted: true`.

The `lint.warnings` array is an **inclusive container**: `severity:
"info"` entries live here alongside `severity: "warn"`. Consumers should
filter on `.severity`. Valid v2 severities: `{"warn", "info"}`. `"error"`
is intentionally excluded — manage must always produce parseable JSON
even when the harness is broken (required for AC-9).

---

## Pre-flight: HR-3 cwd guard

Same as the harness-evaluate and harness-build skills. Manage is read-only
but the cwd guard still runs so hooks cannot silently read from `/` or
`$HOME`.

1. Resolve the target. `--target <path>` if given, else `$PWD`.
2. Resolve symlinks portably: `resolved=$(cd "$target" 2>/dev/null && pwd -P) || { ... }`.
3. Reject and exit `MANAGE_CWD_REJECTED` if `resolved` is `/`, `$HOME`,
   `/tmp`, `/private/tmp`, or non-existent.
4. **No interactive prompt by default.** Unlike `build`, `manage` is
   read-only and designed for hook callability.

---

## Step 1 — Harness inventory

Enumerate harness-shaped files under the resolved target using the same
globs as `harness-evaluate` Step 2 — covering BOTH legacy top-level
locations AND Claude-Code-canonical `.claude/` locations:

```
CLAUDE.md
AGENTS.md
agents/*.md
.claude/agents/**/*.md
skills/**/SKILL.md
.claude/skills/**/SKILL.md
commands/*.md
.claude/commands/**/*.md
.claude/settings.json
hooks/*
.claude/hooks/**
```

For each glob:

- Apply the HR-4 basename denylist (same patterns as `harness-evaluate`
  Step 1.1). Drop matches.
- Count, don't read content (manage is fast).

Populate `inventory`. Each counter sums BOTH the legacy top-level path
and the Claude-Code-canonical `.claude/` path so a project that keeps
its skills under `.claude/skills/` is counted correctly:

| Field                 | Counter                                                                                                                                                                                                                          |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `has_claude_md`       | `[ -f "$resolved/CLAUDE.md" ]`                                                                                                                                                                                                   |
| `has_agents_md`       | `[ -f "$resolved/AGENTS.md" ]`                                                                                                                                                                                                   |
| `skills_count`        | `( find "$resolved/skills" -name SKILL.md -type f 2>/dev/null; find "$resolved/.claude/skills" -name SKILL.md -type f 2>/dev/null ) | wc -l`                                                                                  |
| `agents_count`        | `( find "$resolved/agents" -maxdepth 1 -name '*.md' -type f 2>/dev/null; find "$resolved/.claude/agents" -name '*.md' -type f 2>/dev/null ) | wc -l`  (the top-level `AGENTS.md` advisory file is tracked separately as `has_agents_md`) |
| `commands_count`      | `( find "$resolved/commands" -maxdepth 1 -name '*.md' -type f 2>/dev/null; find "$resolved/.claude/commands" -name '*.md' -type f 2>/dev/null ) | wc -l`                                                                            |
| `hooks_count`         | `( find "$resolved/hooks" -maxdepth 1 -type f 2>/dev/null; find "$resolved/.claude/hooks" -type f 2>/dev/null ) | wc -l`                                                                                                          |
| `harness_files_total` | Sum of the above plus `has_claude_md ? 1 : 0` plus `has_agents_md ? 1 : 0`.                                                                                                                                                       |

Inventory is **descriptive, not prescriptive**. A harness without
`commands/` is not "broken" — it just doesn't have slash commands. The
old 4-bucket "missing buckets" model is retired; project fit is the
standard now (and that's evaluate's job).

---

## Step 2 — Fit drift detection

Drift in v2 means: *has the project moved since the harness was last
reconciled?*

### 2.1 Read recorded state

```bash
state_file="$resolved/.meta-harness/state.json"
if [ -f "$state_file" ]; then
  recorded_hash=$(jq -r '.project_tree_hash // empty' "$state_file" 2>/dev/null)
  recorded_at=$(jq -r '.recorded_at // empty' "$state_file" 2>/dev/null)
fi
```

If the file is absent → `drift.reason = "no_record"`, `drifted = true`.
If the file is present but `recorded_hash` is empty or unparseable →
`drift.reason = "record_corrupt"`, `drifted = true`.

### 2.2 Compute current `project_tree_hash`

Use the **same algorithm** as `harness-evaluate` Step 1: tree enumeration
with ignore-list and HR-4 denylist, top-5 config file selection with the
50 KB / 200-line cap, sorted concatenation, `shasum -a 256`. The hash
must be byte-identical to what evaluate would compute on the same target
at the same moment — that's what makes manage and evaluate
cross-referenceable.

This is the same logic — do not re-implement it differently. The build
skill imports it too (its Step 1).

### 2.3 Compare

```
drifted  := recorded_hash != current_hash
reason   := "none" if (recorded_hash == current_hash) else "tree_hash_diff"
days_since_record := floor((now - recorded_at) / 86400) if recorded_at else null
```

### 2.4 State file shape (informative; written by build/improve, not by manage)

```jsonc
{
  "schema_version": 1,
  "project_tree_hash": "sha256:abc...",
  "harness_state_hash": "sha256:def...",
  "recorded_at": "2026-05-20T08:50:00Z",
  "recorded_by": "harness-build|harness-improve",
  "qualitative_at_record": "good"
}
```

Manage reads `project_tree_hash` and `recorded_at`. The other fields are
informational; manage MAY echo them into the JSON output's `drift` block
in a future version. v2.0 only consumes the hash and the timestamp.

---

## Step 3 — Internal lint

Lint catches structural inconsistencies that the inventory and drift
checks don't see. v2 has five rules. Each produces zero or more warnings
with `id`, `severity`, and human-readable `message`. Severity is `warn`
or `info`. No lint is `error` in v2 — that would block JSON output and
defeat AC-9.

| ID    | Rule                                                                                                                                                | Severity |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `L01` | A `CLAUDE.md` or `SKILL.md` body references a file path (e.g., `lib/foo/bar.ts`) that does not exist in the project. Best-effort regex match.        | warn     |
| `L02` | A `SKILL.md`'s `invokes:` frontmatter names an agent ID that does not appear in `agents/*.md` frontmatter as `agent_id:` (or as a file basename).    | warn     |
| `L03` | A `commands/*.md` `allowed-tools:` entry is not in the known tool catalogue (informational — the catalogue can drift).                              | info     |
| `L04` | A harness file contains a 16+ char base64-ish or hex-ish substring outside whitelisted hash fields (HR-4 sanity check).                              | warn     |
| `L05` | `hooks/hooks.json` exists but registers zero hooks, OR a hook script referenced in `hooks.json` is missing on disk.                                  | info     |

### Implementation notes

- Each rule degrades gracefully. If its inputs are missing (no `skills/`
  at all), the rule emits no warning rather than crashing.
- L01's regex match is best-effort: it looks for tokens shaped like
  `<path>(/<seg>)*\.(ts|tsx|js|jsx|py|rs|go|dart|md|mdx|yaml|yml|json|toml|sql)` in
  the harness file body, then `test -e "$resolved/$token"`. Hits in a
  fenced ` ``` ` code block are skipped (they're examples, not live refs).
- **Extension fallback (to avoid false positives on extension variants):**
  if the primary `test -e` misses, try the following equivalence-class
  variants before reporting the path as missing. Only emit L01 when ALL
  variants are absent:
  - `.ts`   → also try `.tsx`
  - `.js`   → also try `.jsx`
  - `.md`   → also try `.mdx`
  - `.yaml` → also try `.yml`
  - `.yml`  → also try `.yaml`
- L02 normalizes both sides: `invokes: foo` matches `agents/foo.md` OR
  `.claude/agents/foo.md` (or any `.claude/agents/**/foo.md`) whose
  frontmatter declares `agent_id: foo`. If the agent file's frontmatter
  doesn't declare `agent_id`, fall back to basename match. Both legacy
  top-level and Claude-Code-canonical paths are valid resolution targets.
- L03's known tool catalogue (v2): `Read`, `Edit`, `Write`, `Glob`,
  `Grep`, `Bash`, `Task`, `WebFetch`, `WebSearch`, `AskUserQuestion`,
  `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`, plus any tool name
  beginning with `mcp__`. False positives surface as `info`, not `warn`.
- L04 uses the same regex as `harness-evaluate` Step 4.4
  (`[A-Za-z0-9+/=]{16,}`) and whitelists `project_tree_hash`,
  `harness_state_hash`, `evaluator_model_id`, and any value inside a
  frontmatter `*_hash:` field.

---

## Step 4 — JSON render + human summary

1. Assemble the JSON object per the schema in §Outputs.
2. `checked_at = date -u +%Y-%m-%dT%H:%M:%SZ`.
3. Print JSON to stdout exactly once. If `--write-report <path>` is given,
   also atomically write the JSON to `<path>` (`.tmp.$$` → `mv`, same
   pattern as `harness-build` Step 7.2).
4. If `--json-only` is NOT set AND `--silent` is NOT set, print the human
   summary AFTER the JSON, separated by a single blank line. The JSON
   must be the first thing on stdout so pipelines like
   `manage --json-only | jq -e '.drift.drifted'` work without preamble noise.
5. If `--silent` is set, stdout is suppressed entirely (used when manage
   runs from a hook with `--write-report` to a file).

### Scope of lint rules (honest disclosure)

Lint in v2 is intentionally narrow. It catches five specific structural
mistakes. It does NOT validate:

- Project-harness fit quality (that's evaluate's job)
- Whether a skill is semantically usable (no LLM call)
- Whether a referenced file *should* exist (L01 catches dangling refs,
  not missing-but-needed refs)
- License compatibility
- SemVer correctness of any CHANGELOG

A clean manage report means *"these five rules pass and the project tree
hasn't moved since record."* A real fit verdict requires
`/meta-harness:evaluate`.

---

## AC-9 contract (binding, v2 form)

AC-9 in v2 is the gate that defines whether this skill works. In words:

> When `/meta-harness:manage` runs against a fixture project that has
> moved since the recorded `project_tree_hash` (or has no recorded state),
> the resulting JSON output's `drift.drifted` field MUST be `true`.
> Conversely, when the project has not moved since record, `drift.drifted`
> MUST be `false`.

Mechanical verification:

```bash
# Fixture A: drift = true (no state file)
rm -rf /tmp/m4-fixture-a && mkdir -p /tmp/m4-fixture-a/{src,agents,skills/x}
printf 'export const a = 1;\n' > /tmp/m4-fixture-a/src/index.ts
printf '# Fixture\n' > /tmp/m4-fixture-a/CLAUDE.md
printf '# fixture agent\n' > /tmp/m4-fixture-a/agents/x.md
printf '# fixture skill\n' > /tmp/m4-fixture-a/skills/x/SKILL.md

manage_json=$(/meta-harness:manage --target /tmp/m4-fixture-a --json-only)
echo "$manage_json" | jq -e '.drift.drifted == true' \
  || { echo "AC-9a FAIL" >&2; exit 1; }
echo "$manage_json" | jq -e '.drift.reason == "no_record"' \
  || { echo "AC-9a reason FAIL" >&2; exit 1; }
echo "AC-9a PASS"

# Fixture B: drift = false (state recorded, project unchanged)
recorded_hash=$(echo "$manage_json" | jq -r '.drift.current_project_tree_hash')
mkdir -p /tmp/m4-fixture-a/.meta-harness
cat > /tmp/m4-fixture-a/.meta-harness/state.json <<EOF
{ "schema_version": 1,
  "project_tree_hash": "$recorded_hash",
  "recorded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "recorded_by": "test-fixture" }
EOF

manage_json2=$(/meta-harness:manage --target /tmp/m4-fixture-a --json-only)
echo "$manage_json2" | jq -e '.drift.drifted == false' \
  || { echo "AC-9b FAIL" >&2; exit 1; }
echo "AC-9b PASS"

# Fixture C: drift = true after project mutation
printf 'export const b = 2;\n' > /tmp/m4-fixture-a/src/new_file.ts
manage_json3=$(/meta-harness:manage --target /tmp/m4-fixture-a --json-only)
echo "$manage_json3" | jq -e '.drift.drifted == true and .drift.reason == "tree_hash_diff"' \
  || { echo "AC-9c FAIL" >&2; exit 1; }
echo "AC-9c PASS"
```

All three fixtures must pass. The verifier uses `jq -e` so non-zero exit
means manage either produced invalid JSON or got the drift bit wrong.

---

## Failure modes

| Code                          | Meaning                                                                                  | Exit |
| ----------------------------- | ---------------------------------------------------------------------------------------- | ---- |
| `MANAGE_CWD_REJECTED`         | Pre-flight refused the target (not a directory, blocked path, or symlink to one).        | 1    |
| `MANAGE_REPORT_WRITE_FAILED`  | `--write-report <path>` was given but the atomic write failed. JSON already on stdout.   | 3    |
| `MANAGE_BAD_ARGS`             | Contradictory or malformed argv (e.g., `--write-report` with no value, parent dir absent). | 4    |
| `MANAGE_DENYLIST_LEAKED <path>` | A harness file contains a denylist hit AND that content would have been rendered to stdout. The skill replaces the hit with `<REDACTED>` and adds an L04 warning; it does NOT fail the run. The error code is reserved for a future strict mode and is not emitted by v2.0. | (reserved) |

**No failure mode is "lint found warnings"**. Lint warnings are data on
the happy path. A hook-callable healthcheck that exited non-zero on lint
would spam SessionStart errors.

**No failure mode is "drift detected"**. Drift is information. The
operator (or the calling hook) decides what to do with it — most likely,
run `/meta-harness:evaluate` next.

---

## Integration with hooks (default OFF per ADR-0003)

`hooks/session-start-healthcheck.sh` (M6 deliverable) invokes manage like:

```bash
/meta-harness:manage \
  --target "$CLAUDE_PROJECT_DIR" \
  --json-only --silent \
  --write-report ".meta-harness/reports/$(date -u +%Y%m%dT%H%M%SZ)-manage.json"
```

`--silent` suppresses stdout entirely. The default hooks registry has
this hook `enabled: false`; the operator must explicitly opt in.

Output reports land in `<target>/.meta-harness/reports/`. Retention is
the operator's responsibility.

---

## Out of scope for v2

- **Automatic remediation.** Manage reports; it does not fix. Fixes go
  through `/meta-harness:build` (for missing core scaffold) or
  `/meta-harness:improve` (for finding-driven patches).
- **Analyzer invocation.** Manage stays LLM-free. If the operator wants
  the analyzer's findings, they run `/meta-harness:evaluate`.
- **Multi-harness aggregation.** Each manage call inspects one target.
  Walking a monorepo is the caller's job.
- **Semantic drift.** Manage detects hash drift only. A project rename
  that preserves the tree shape reads as "no drift" even though the
  intent shifted; evaluate-then-improve is the path for catching that.
- **Active enforcement.** L01's stale-reference check is informational.
  The operator (or improve) decides whether to delete, rename, or update
  the reference.

---

## What changed vs. v1.x

For operators upgrading from a v1.x manage harness:

| v1.x (4-bucket presence + KB drift)                                | v2.0 (fit-drift + inventory)                                       |
| ------------------------------------------------------------------ | ------------------------------------------------------------------ |
| `healthcheck.present_buckets` / `missing_buckets` / `stale_buckets` | `inventory` (descriptive counts) — buckets retired                 |
| `kb_diff.project_kb_manifest_hash` / `.plugin_kb_manifest_hash`    | `drift.recorded_project_tree_hash` / `.current_project_tree_hash`  |
| Required `<plugin_root>/docs/kb-manifest.json`                     | No plugin-side KB; state lives in target's `.meta-harness/state.json` |
| `MANAGE_KB_MISSING` failure mode                                   | Retired — no KB to be missing                                      |
| Lint rules L01–L04 (KB-version-centric)                            | Lint rules L01–L05 (project-fit-centric, see Step 3)               |
| AC-9: `missing_buckets` must include `"persona"` on agent-less fixture | AC-9: `drift.drifted` must be `true` on no-record / moved-project fixtures |

---

## See also

- `commands/manage.md` — the thin user-facing trigger.
- `skills/harness-evaluate/SKILL.md` — sibling skill; canonical Step 1
  (project sketch + tree hash) algorithm this skill imports.
- `skills/harness-build/SKILL.md` — writes `state.json` after a successful
  build; this skill reads it.
- `skills/harness-improve/SKILL.md` — writes `state.json` after a
  successful improvement; this skill reads it too.
- `agents/project-fit-analyzer.md` — manage does NOT invoke the analyzer
  directly, but its output (`drift.drifted == true`) is the cue an
  operator uses to run evaluate, which does.
