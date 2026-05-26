---
skill_id: harness-manage
name: Harness Manage Workflow
description: "Procedural workflow for /meta-harness:manage. Enumerates 4-bucket presence, computes KB drift between the project's vendored evaluator and the plugin's current KB, runs internal lint, and renders a strict JSON report. AC-9 (F1 disposition) is the binding contract — missing bucket detection is the verifiable output."
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
SessionStart hook (default OFF, see ADR-0003) follow this skill verbatim.

`manage` is **read-only by default**. It does not modify the target harness;
its job is to produce a structured healthcheck report that downstream tools
(or the operator) can act on. The only write side-effect is the JSON report
itself, and only when `--write-report <path>` is given; the default behavior
is stdout.

The skill is procedural. It does NOT redefine the 4-bucket model — that
lives in `docs/theory/harness-4-bucket-principles.md` (KB-3). It does NOT
score the harness — that is `/meta-harness:evaluate`'s job.

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Target project root | `--target <path>` arg, else `$PWD` | Yes |
| Plugin KB manifest | `<plugin_root>/docs/kb-manifest.json` | Yes (fail-closed if absent or empty) |
| Plugin KB set version | `<plugin_root>/docs/kb-manifest.json` `.kb_set_version` | Yes |
| Project vendored evaluator | `<target>/agents/karpathy-evaluator.md` (if present) | No (its absence is itself a finding) |

`<plugin_root>` is resolved as in the harness-build skill: `$CLAUDE_PLUGIN_ROOT`
env var if set, otherwise the directory containing this `SKILL.md`'s parent's
parent (i.e. `dirname/dirname` of this file). See `skills/harness-build/SKILL.md`
§Plugin install root resolution for the canonical pattern.

---

## Outputs

1. **Strict JSON** matching the schema below. This is the primary artifact;
   downstream `--json-only` callers and AC-9 verification both depend on it
   parsing cleanly.
2. **Human summary** (6–14 lines) on stdout when `--json-only` is NOT set:
   - Line 1: `target: <resolved-path>`
   - Line 2: `buckets present: <N>/4 — <comma-list>`
   - Line 3: `buckets missing: <list-or-"none">`
   - Line 4: `buckets stale: <list-or-"none">`
   - Line 5: `KB drift: <yes/no> (project=<hash[:8]>, plugin=<hash[:8]>)`
   - Line 6: `lint warnings: <count>`
   - Lines 7–14 (optional): one line per warning, indented two spaces.

### JSON output schema

```json
{
  "schema_version": 1,
  "manage_version": "1.0.0",
  "meta": {
    "target": "/abs/path",
    "checked_at": "2026-05-26T08:50:00Z",
    "plugin_root": "/abs/plugin/path"
  },
  "healthcheck": {
    "present_buckets": ["persona", "capabilities", "runtime", "meta_gov"],
    "missing_buckets": [],
    "stale_buckets": []
  },
  "kb_diff": {
    "project_kb_manifest_hash": "sha256:...",
    "plugin_kb_manifest_hash": "sha256:...",
    "project_kb_set_version": "1.0.0",
    "plugin_kb_set_version": "1.0.0",
    "vendored_at": "2026-05-26T07:30:00Z",
    "drift": false
  },
  "lint": {
    "warnings": [
      { "id": "L01", "severity": "warn", "message": "skills/foo/SKILL.md references agent 'bar' which is not defined under agents/" },
      { "id": "L02", "severity": "info", "message": "commands/foo.md allowed-tools entry 'CustomTool' not in known catalogue (info — catalogue may drift)" }
    ]
  }
}
```

Each `present_buckets` / `missing_buckets` entry uses one of exactly:
`"persona"`, `"capabilities"`, `"runtime"`, `"meta_gov"`. No other strings.
`stale_buckets` uses the same vocabulary; "stale" means the bucket is present
on disk but a KB drift or a structural problem makes its score untrustworthy.
**Example populated `stale_buckets`**: when `kb_diff.drift == true` and the
project's vendored evaluator (persona bucket) is on disk, the result reads
`"stale_buckets": ["persona"]` — present-but-untrustworthy.

The `lint.warnings` array is an **inclusive container**: entries with
`severity: "info"` live here too, alongside `severity: "warn"` entries. The
naming is historical and is slated for rename to `lint.findings` in v1.1.
Consumers parsing the array should filter on `.severity` rather than
inferring severity from the container name. The valid severity vocabulary
in v1 is exactly `{"warn", "info"}`; `"error"` is intentionally excluded
to keep the JSON output parseable under all conditions (required for AC-9).

---

## Pre-flight: HR-3 cwd guard

Same as the harness-evaluate and harness-build skills. Manage does not write
to the project by default, but the cwd guard still runs so that hooks and
scripted invocations cannot silently read from `/` or `$HOME`.

1. Resolve the target. If `--target <path>` is given, use that; otherwise
   use `$PWD`.
2. Resolve symlinks portably with `pwd -P`:
   ```bash
   resolved=$(cd "$target" 2>/dev/null && pwd -P) || {
     printf 'MANAGE_CWD_REJECTED %s\n' "$target" >&2
     exit 1
   }
   ```
3. Reject and exit `MANAGE_CWD_REJECTED` if the resolved path is `/`,
   `$HOME` exactly, `/tmp`, `/private/tmp`, or non-existent.
4. **No interactive prompt by default.** Unlike `build`, `manage` is read-only
   and is designed to be hook-callable; an interactive prompt would break
   the SessionStart use case. The reject path above is the entire guard.
   `--interactive` flag (reserved, not implemented v1) would re-enable the
   "Treat this directory as the project root?" prompt.

---

## Step 1: Bucket enumeration

The 4-bucket model from KB-3. Each bucket has a **minimum existence rule**:
a bucket is `present` iff its rule evaluates true on the target. Anything
short of the rule lands in `missing`.

| Bucket | Existence rule | Files inspected |
|--------|---------------|-----------------|
| `persona` | `CLAUDE.md` exists AND `agents/` contains ≥1 `*.md` file | `CLAUDE.md`, `agents/*.md` |
| `capabilities` | `skills/` contains ≥1 `*/SKILL.md` AND `commands/` contains ≥1 `*.md` | `skills/**/SKILL.md`, `commands/*.md` |
| `runtime` | `.claude/settings.json` exists AND `hooks/` directory exists (may be empty or default OFF) | `.claude/settings.json`, `hooks/` |
| `meta_gov` | `README.md` exists AND `CHANGELOG.md` exists | `README.md`, `CHANGELOG.md` |

Evaluation order is fixed: persona, capabilities, runtime, meta_gov. Each
rule is evaluated independently — failing one bucket never short-circuits
the others. This is what AC-9 leans on: when `agents/` is intentionally
missing, the `persona` rule fails and `"persona"` lands in `missing_buckets`,
regardless of what the other three buckets look like.

Portable shell sketch (mirror this in the skill execution). Uses `find`
rather than glob expansion to avoid shell-specific `nomatch` chatter
(zsh) versus silent-empty (bash with `nullglob` off):

```bash
has_md() {
  # has_md DIR — true iff DIR exists and contains at least one *.md file
  # at depth 1 (or with arbitrary depth when pattern is empty). Suppresses
  # stderr to keep noise out of the JSON output stream.
  find "$1" -maxdepth 1 -type f -name '*.md' -print -quit 2>/dev/null \
    | grep -q .
}
has_skill() {
  find "$1" -mindepth 2 -maxdepth 2 -type f -name 'SKILL.md' \
    -print -quit 2>/dev/null | grep -q .
}

present=()
missing=()

# persona
if [ -f "$target/CLAUDE.md" ] && has_md "$target/agents"; then
  present+=("persona")
else
  missing+=("persona")
fi

# capabilities
if has_skill "$target/skills" && has_md "$target/commands"; then
  present+=("capabilities")
else
  missing+=("capabilities")
fi

# runtime
if [ -f "$target/.claude/settings.json" ] && [ -d "$target/hooks" ]; then
  present+=("runtime")
else
  missing+=("runtime")
fi

# meta_gov
if [ -f "$target/README.md" ] && [ -f "$target/CHANGELOG.md" ]; then
  present+=("meta_gov")
else
  missing+=("meta_gov")
fi
```

The above is illustrative. The actual implementation is a shell snippet
in the harness procedure — no separate script is required for v1, since
manage runs once per invocation and the enumeration is small. Implementors
running under zsh should keep the `find` form above; the equivalent `ls
$dir/*.md >/dev/null 2>&1` works in bash but leaks `nomatch` notices in
zsh and is therefore avoided here.

---

## Step 2: KB drift detection

The vendored copy of `agents/karpathy-evaluator.md` in the target project
carries the KB set version and manifest hash in its frontmatter (set by
`/meta-harness:build` at vendor time). The plugin's current KB has its own
manifest in `<plugin_root>/docs/kb-manifest.json`. If the two diverge, the
project's evaluator is judging against a stale rubric and any score it
produces is suspect.

1. Read the project's vendored evaluator frontmatter (if persona bucket
   present):
   ```bash
   if [ -f "$target/agents/karpathy-evaluator.md" ]; then
     project_kb_set_version=$(awk '/^kb_set_version:/{print $2; exit}' \
       "$target/agents/karpathy-evaluator.md")
     project_kb_manifest_hash=$(awk '/^kb_manifest_hash:/{print $2; exit}' \
       "$target/agents/karpathy-evaluator.md")
     vendored_at=$(awk '/^vendored_at:/{print $2; exit}' \
       "$target/agents/karpathy-evaluator.md")
   fi
   ```
2. Read the plugin's current manifest:
   ```bash
   plugin_kb_set_version=$(jq -r '.kb_set_version' "$plugin_root/docs/kb-manifest.json")
   plugin_kb_manifest_hash=$(jq -r '.combined_hash' "$plugin_root/docs/kb-manifest.json")
   ```
3. `drift = (project_kb_manifest_hash != plugin_kb_manifest_hash)`. If the
   project's frontmatter values are absent (no persona bucket, or older
   build version that didn't record them), set both project fields to `null`
   and `drift = true` — the missing record is itself a drift signal.
4. When `drift = true`, also append `"persona"` to `stale_buckets` IF persona
   is in `present_buckets`. (A bucket can be both present and stale; it
   cannot be both missing and stale — missing wins.)

---

## Step 3: Internal lint

Internal lint catches structural inconsistencies that the bucket check
can't see. v1 has four lint rules; each produces zero or more warnings
with `id`, `severity`, and human-readable `message`. Severity is one of
`warn` (default) or `info`. No lint is `error` in v1 — that would block
the JSON output, which would defeat AC-9's "manage on broken harness still
returns parseable JSON" contract.

| ID | Rule | Severity |
|----|------|----------|
| `L01` | A `skills/**/SKILL.md` `invokes:` entry names an agent file that does not exist under `agents/`. | warn |
| `L02` | A `commands/*.md` `allowed-tools:` list references a tool name not in Claude Code's known tool catalogue (best-effort check; the catalogue is hardcoded in the lint rule). | info |
| `L03` | `hooks/hooks.json` exists but has zero registered hooks (file present but vestigial). | info |
| `L04` | KB set version on disk under `docs/theory/*.md` frontmatter is older than the version recorded in `agents/karpathy-evaluator.md` frontmatter (project vendored a newer KB than its own theory files declare). | warn |

Implementation note: each lint rule must degrade gracefully — if its
inputs are missing (e.g., no `skills/` at all), the rule emits no warning
rather than crashing. The lint section's `warnings` array can be empty.

The known tool catalogue for L02 is: `Read`, `Edit`, `Write`, `Glob`,
`Grep`, `Bash`, `Task`, `WebFetch`, `WebSearch`, `AskUserQuestion`, plus
any tool name beginning with `mcp__`. Anything else triggers L02. This
list is intentionally conservative; false positives are surfaced as
`info` rather than `warn` precisely because the catalogue can drift.

---

## Step 4: JSON render + human summary

1. Assemble the JSON object per the schema in §Outputs.
2. Compute `checked_at` as `date -u +%Y-%m-%dT%H:%M:%SZ`.
3. Print JSON to stdout exactly once. If `--write-report <path>` is given,
   also atomically write the JSON to `<path>` (`.tmp.$$` → `mv`, same
   atomic pattern as harness-build §Step 4).
4. If `--json-only` is NOT set, print the human summary AFTER the JSON,
   separated by a single blank line. Order matters: the JSON must be the
   first thing on stdout so that pipelines like
   `manage --json-only | jq -e '.healthcheck.missing_buckets | index("persona")'`
   work without preamble noise. With `--json-only`, the human summary is
   suppressed entirely (JSON-only is the strict mode AC-9 verifications use).

### Scope of lint rules (honest disclosure)

Lint rules in v1 are intentionally narrow. They catch four specific
structural mistakes. They do **not** validate:

- KB content quality (that's `/meta-harness:evaluate`'s job)
- Whether a skill is actually usable (no semantic check, just file presence)
- Whether referenced files exist (other than the L01 agent check)
- License compatibility
- SemVer correctness of the harness's CHANGELOG

These are listed here so that an operator reading a clean lint report
does not over-trust "no warnings" as "harness is fully healthy". A clean
manage report means "the four enumerated rules pass"; a real health
verdict requires `/meta-harness:evaluate`.

---

## AC-9 contract (binding)

AC-9 is the gate that defines whether this skill works. In words:

> When `/meta-harness:manage` runs against a fixture harness that has
> `agents/` absent (or empty of `.md` files), the resulting JSON output's
> `healthcheck.missing_buckets` array MUST contain the string `"persona"`.

Mechanical verification (this is what M4 ships against):

```bash
# fixture: a harness with everything except agents/
rm -rf /tmp/m4-fixture && mkdir -p /tmp/m4-fixture/{skills/x,commands,hooks,.claude}
printf '# Fixture\n' > /tmp/m4-fixture/CLAUDE.md
printf '# fixture skill\n' > /tmp/m4-fixture/skills/x/SKILL.md
printf '# fixture command\n' > /tmp/m4-fixture/commands/x.md
printf '{}\n' > /tmp/m4-fixture/.claude/settings.json
printf '# Fixture\n' > /tmp/m4-fixture/README.md
printf '# Changelog\n' > /tmp/m4-fixture/CHANGELOG.md
# note: no agents/ directory — persona bucket should be missing

manage_json=$(/meta-harness:manage --target /tmp/m4-fixture --json-only)
echo "$manage_json" | jq -e '.healthcheck.missing_buckets | index("persona")' \
  || { echo "AC-9 FAIL" >&2; exit 1; }
echo "AC-9 PASS"
```

`jq -e` exits 0 when its filter result is truthy (a number, here the index
of `"persona"` in the array). Any non-zero exit means AC-9 failed — either
manage didn't include `"persona"` in `missing_buckets`, or the output
wasn't valid JSON. The generalized form is documented in REQUESTS.md §AC-9:
removing `commands/*.md` makes `capabilities` missing, removing
`.claude/settings.json` makes `runtime` missing, removing `README.md` makes
`meta_gov` missing. All four must be checkable by the same `jq` pattern.

---

## Failure modes

| Code | Meaning | Exit |
|------|---------|------|
| `MANAGE_CWD_REJECTED` | Pre-flight refused the target (not a directory, blocked path, or symlink to one). | 1 |
| `MANAGE_KB_MISSING` | The plugin's `docs/kb-manifest.json` is absent or empty. Without it the skill cannot compute drift; emitting "drift=false" by default would be a silent lie. | 2 |
| `MANAGE_REPORT_WRITE_FAILED` | `--write-report <path>` was given but the atomic write failed (rename or tmpfile create). The JSON has still been printed to stdout, so the operator sees the report; only the side-effect file is missing. | 3 |
| `MANAGE_BAD_ARGS` | Contradictory or malformed argv. v1-reachable examples: `--write-report` with no value, `--write-report <path>` whose parent directory does not exist, or `--json-only` together with the reserved (not-implemented in v1) `--interactive` flag. | 4 |

Note that **no failure mode is "lint found warnings"**. Lint warnings are
data on the happy path, not errors. This is intentional: a hook-callable
healthcheck must not fail just because of a stylistic issue, otherwise
SessionStart loops will spam errors.

---

## Integration with hooks (default OFF per ADR-0003)

`hooks/session-start-healthcheck.sh` (M6 deliverable) invokes manage like:

```bash
/meta-harness:manage --target "$CLAUDE_PROJECT_DIR" --json-only --silent \
  --write-report ".meta-harness/reports/$(date -u +%Y%m%dT%H%M%SZ)-manage.json"
```

`--silent` suppresses stdout entirely (used when manage runs in the
background). The default hooks registry has this hook `enabled: false`
per AC-5; the operator must explicitly opt in.

Output reports written by hooks land in `<target>/.meta-harness/reports/`.
Snapshot/report retention is the operator's responsibility — same policy
as harness-build §Step 4.3.

---

## Out of scope for v1

- **Automatic remediation.** Manage reports; it does not fix. Fixes go
  through `/meta-harness:build` (for missing files) or `/meta-harness:improve`
  (for low scores). Coupling manage to remediation would conflate the
  diagnostic and treatment roles.
- **Multi-harness aggregation.** Each manage call inspects one target.
  Walking a monorepo of harnesses is the caller's job.
- **KB content drift (beyond the manifest hash).** v1 detects hash drift
  only; semantic drift (KB-1 reworded but hash differs by a byte) reads
  identically to a meaningful change. The hash is the only honest signal
  the static KB choice (ADR-0001) provides.

---

## See also

- `commands/manage.md` — the thin user-facing trigger.
- `docs/theory/harness-4-bucket-principles.md` — KB-3, source of truth
  for what the 4 buckets are.
- `docs/kb-manifest.json` — the plugin-side manifest manage reads for drift.
- `agents/karpathy-evaluator.md` — vendored copy carries the project-side
  hash that manage compares against.
- `skills/harness-build/SKILL.md` — atomic write pattern manage reuses for
  `--write-report`.
- `skills/harness-evaluate/SKILL.md` — sibling read-only skill; manage's
  pre-flight pattern matches it.
