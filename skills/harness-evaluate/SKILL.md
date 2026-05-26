---
skill_id: harness-evaluate
name: Harness Evaluate Workflow
description: "Procedural workflow for /meta-harness:evaluate. Collects target project harness files, applies secret denylist, resolves the KB manifest hash, invokes the karpathy-evaluator agent, strict-validates the JSON response, and renders the result."
invoked_by:
  - commands/evaluate.md
invokes:
  - agents/karpathy-evaluator
related_requirements: [FR-4, NFR-1, NFR-3, NFR-5, HR-1, HR-3, HR-4, AC-2, AC-6, AC-7]
related_adrs: [ADR-0002, ADR-0003]
---

# Harness Evaluate — workflow skill

This skill is the **single source of truth** for the `/meta-harness:evaluate`
procedure. Both the slash command (`commands/evaluate.md`) and any opt-in
hook (`hooks/stop-evaluate.sh`, default OFF — see ADR-0003) follow this skill
verbatim.

The skill is procedural only. It does NOT redefine the evaluator's output
schema — that lives in `agents/karpathy-evaluator.md`. It does NOT redefine
the rubric — that lives in `docs/theory/harness-4-bucket-principles.md`
(KB-3).

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Target project root | `--target <path>` arg, else `$PWD` | Yes |
| KB files | `docs/theory/{karpathy-context-engineering,anthropic-agentic-loops,harness-4-bucket-principles}.md` (relative to the plugin install root) | Yes (fail-closed if absent — FR-4) |
| KB manifest | `docs/kb-manifest.json` | Yes |
| Evaluator agent | `agents/karpathy-evaluator.md` | Yes |
| Runtime model id | Inherited from the host harness (see Step 3) | Yes |

---

## Outputs

1. **Strict JSON** matching `agents/karpathy-evaluator.md` §Output contract.
2. **Human summary** (6–12 lines):
   - Line 1: `Total: NN / 20`
   - Lines 2–5: `  Persona: N/5  — <first sentence of rationale>` (one per axis)
   - Line 6: `kb_manifest_hash: <hash>`
   - Line 7: `evaluator_model_id: <id>`
   - Line 8: `timestamp: <iso8601>`
   - Lines 9–12 (optional): lowest-scoring axis observation (no prescriptive fix
     here — that's the `harness-improve` skill's job).

---

## Pre-flight: HR-3 cwd guard

Before anything else, before any file read other than the target directory's
existence check:

1. Resolve the target. If `$1` looks like `--target <path>`, use that;
   otherwise use `$PWD`.
2. **Resolve symlinks portably** before comparing. Use `pwd -P` after `cd`:
   `resolved=$(cd "$target" 2>/dev/null && pwd -P)` — POSIX, works on macOS
   (where default `readlink` lacks `-f`) and Linux. Compare `$resolved`, not
   `$target`, against the reject list.
3. **Reject** the resolved target if any of:
   - Path equals `/`
   - Path equals `$HOME` (exactly)
   - Path equals `/tmp` or `/private/tmp`
   - Path does not exist or is not a directory
   On rejection: emit `EVAL_CWD_REJECTED <reason>` on stderr, exit non-zero.
4. **Print** the cwd line and the candidate file globs (verbatim format from
   `commands/evaluate.md`).
5. **Soft-check** for harness-shaped content. If the target has none of
   `.claude/`, `CLAUDE.md`, `agents/`, `skills/`, the skill in interactive
   mode prompts `"This directory does not look like a Claude Code project
   root. Continue? [y/N]"`. In non-interactive mode (hook), fail-closed with
   `EVAL_NOT_A_PROJECT`.

This guard runs first in the skill even though the command also runs it —
defense in depth (ADR-0003).

---

## Step 1 — Enumerate target files and apply the secret denylist (AC-7 / HR-4)

### 1.1 Enumerate candidate paths

Within the resolved target root, enumerate the following globs (any of them
that exist):

```
CLAUDE.md
agents/*.md
skills/**/SKILL.md
commands/*.md
.claude/settings.json
hooks/*
README.md
CHANGELOG.md
docs/ADR-*.md
```

Use a portable enumeration (e.g., `find` with `-maxdepth` per glob).

### 1.2 Apply the secret denylist

Drop any candidate whose **basename** matches any of these case-sensitive
glob patterns (anchored — entire basename matches):

| Pattern | Examples it drops |
|---------|--------------------|
| `.env*` | `.env`, `.env.local`, `.env.production`, `.environment` |
| `id_rsa*` | `id_rsa`, `id_rsa.pub`, `id_rsa.bak` |
| `*.pem` | `cert.pem`, `key.pem` |
| `*.key` | `private.key`, `app.key` |
| `credentials.*` | `credentials.json`, `credentials.yaml` |
| `secrets.*` | `secrets.json`, `secrets.env` |

The equivalent extended-regex (used by `find -E ... -regex` or `grep -E`) is:

```
^(\.env.*|id_rsa.*|.*\.pem|.*\.key|credentials\..*|secrets\..*)$
```

In bash with `[[` you can use:

```
shopt -s extglob
case "$basename" in
  .env*|id_rsa*|*.pem|*.key|credentials.*|secrets.*) drop=1 ;;
  *) drop=0 ;;
esac
```

This filter is applied **before** any file content is read or passed to the
evaluator. Document every dropped path in the skill's log line:

```
denylist_filter: dropped <count> files: <path1>, <path2>, ...
```

### 1.3 Test fixture (sanity check for AC-7)

Demonstration (you do not invoke the evaluator for this — it's a static
documentation check):

Given a target containing
```
.env
CLAUDE.md
agents/karpathy-evaluator.md
id_rsa
credentials.json
```

After Step 1.2 runs, the file list passed to the evaluator must be exactly:

```
CLAUDE.md
agents/karpathy-evaluator.md
```

— and `.env`, `id_rsa`, `credentials.json` must NOT appear in the evaluator
input or in the rendered output. If any of those three names appear in the
evaluator's response, fail-closed with `EVAL_DENYLIST_LEAKED`.

### 1.4 Defense in depth: output-side masking

In addition to the input-side drop, the skill scans the evaluator's response
for any 16+ character base64-ish or hex-ish string OUTSIDE of the
`kb_citations[*].criterion_id` field and replaces it with `<REDACTED>`. The
regex used:

```
[A-Za-z0-9+/=]{16,}
```

This is a belt-and-suspenders for HR-4. It runs even when the input filter
correctly dropped the secret file.

---

## Step 2 — Resolve the KB manifest hash (AK-M1-2)

The bundled `docs/kb-manifest.json` ships with `PLACEHOLDER_TO_BE_COMPUTED`
strings. They MUST be resolved to real hashes before the evaluator is
invoked. There are two paths:

### Option A (preferred) — invoke the builder script once

```
scripts/build-kb-manifest.sh
```

This script:
- Reads `docs/kb-manifest.json` to find entries.
- Computes `sha256` per entry's `path` (uses `shasum -a 256` on macOS,
  `sha256sum` on Linux).
- Sorts entries by `kb_id` lexicographically.
- Computes `combined_hash = sha256( concat of sorted entry sha256 strings )`.
- Writes back atomically (`.tmp` then `mv`).
- Exit 0 on success.

The skill calls this script once at the start of every evaluate run. It is
idempotent — if all hashes already match the file contents, the writeback is
still atomic and a no-op-in-effect.

### Option B — fallback inline

If the script is missing (operator broke the plugin install), inline-compute:

```
combined=""
for entry in $(jq -r '.entries | sort_by(.kb_id) | .[] | .path' docs/kb-manifest.json); do
  h=$(shasum -a 256 "$entry" | awk '{print $1}')
  combined="${combined}${h}"
done
combined_hash="sha256:$(printf '%s' "$combined" | shasum -a 256 | awk '{print $1}')"
```

Use the resulting `combined_hash` for the next step.

### Failure mode

If any KB file referenced in the manifest does not exist on disk, fail-closed
with `EVAL_KB_MISSING <path>`. Do NOT invoke the evaluator (FR-4).

---

## Step 3 — Invoke the evaluator

Use the Task tool (or the plugin runtime's equivalent sub-agent dispatcher)
to invoke `agents/karpathy-evaluator`. The agent's input expectations come
from its `input_contract` in `agents/karpathy-evaluator.md`.

### 3.1 evaluator_model_id injection pattern

The agent must echo a real `evaluator_model_id` in its JSON, not the literal
placeholder. Since the agent itself cannot reliably introspect "which model
am I running on" (Claude Code may use any compatible model and the agent's
own `model_settings.temperature: 0` does not pin a specific model id), the
**skill is responsible** for capturing the runtime model id from the harness
context and prepending it to the prompt.

Capture order, first hit wins:

1. Environment variable `META_HARNESS_EVALUATOR_MODEL_ID` (operator override).
2. Environment variable `CLAUDE_CODE_MODEL` or `ANTHROPIC_MODEL` if exposed
   by the host harness.
3. The session's own announced model id (e.g., `claude-opus-4-7`), discovered
   from the harness state file (if present at runtime).
4. Fallback literal `claude-unknown` — and log a warning to stderr. The
   validator will still pass (non-empty, not the placeholder), but operators
   should investigate.

Concrete example of the prompt prefix the skill prepends to the agent
invocation:

```
[skill: harness-evaluate]
runtime_evaluator_model_id: claude-opus-4-7
kb_manifest_hash: sha256:0c0937d8edc51b02d206afd6f4458efc6e20559bd169a4dd909c6af491fbdebd

Use the value of runtime_evaluator_model_id verbatim as the JSON field
`evaluator_model_id`. Use the value of kb_manifest_hash verbatim as the
JSON field `kb_manifest_hash`. Do NOT emit any placeholder strings.

--- KB-1 (karpathy-context-engineering) ---
<full content of docs/theory/karpathy-context-engineering.md>

--- KB-2 (anthropic-agentic-loops) ---
<full content of docs/theory/anthropic-agentic-loops.md>

--- KB-3 (harness-4-bucket-principles) ---
<full content of docs/theory/harness-4-bucket-principles.md>

--- TARGET PROJECT FILES (denylist-filtered) ---
<path>: <content>
<path>: <content>
...
```

The agent then runs as defined in `agents/karpathy-evaluator.md`.

### 3.2 Token budget guard (NFR-2 informational)

If the assembled prompt exceeds ~200K input tokens (rough character heuristic:
~4 chars/token → ~800K chars), log a warning to stderr but do NOT abort.
NFR-2 budget is advisory in v1 (F2 deferred per PLAN §4).

---

## Step 4 — Strict JSON parse + schema validate

The evaluator's response goes through:

1. Trim any leading / trailing whitespace.
2. Reject if the response does not start with `{` and end with `}` after
   trimming. (The agent is instructed: strict JSON only, no fences, no
   prose.)
3. Parse with `jq`. If parse fails, this is the first malformed attempt.
4. Run `scripts/validate-eval-output.sh` against the parsed JSON.

### Retry policy (N=1)

Per `agents/karpathy-evaluator.md` §Execution settings, the receiving side
retries up to N=1. Concretely:

- First attempt: malformed or validator-rejected → re-invoke the evaluator
  once with an appended note: `"Your previous response failed strict JSON
  schema validation. Return EXACTLY the schema in agents/karpathy-evaluator.md.
  No prose, no fences."`
- Second attempt: also malformed or rejected → fail-closed with
  `EVAL_INVALID_JSON` on stderr; do not show the user any score.

The retry is for transient LLM noise, not for "convince the model to score
differently". Do not modify the rubric prompt between attempts.

### Scope of c07/c08 (structural-only)

The validator's `c07_rationale_len_80` and `c08_rationale_criterion_ids` checks
enforce **structural compliance only**: a rationale must be ≥80 characters long
and must contain a per-axis criterion-ID token (`PER-[1-5]`, `CAP-[1-5]`,
`RUN-[1-5]`, or `MG-[1-5]`). A lazily padded string like `"xxx ... PER-3"` will
technically pass both. Semantic anti-vacuous quality (the rationale actually
naming the observed behavior) is enforced upstream by the evaluator agent's
system prompt — see `agents/karpathy-evaluator.md` §Per-axis rationale length
guard. The receiving side does not attempt heuristic semantic gating in v1.

---

## Step 5 — Render output

### 5.1 JSON

Emit the validated JSON to stdout, pretty-printed by `jq .`. If `--raw-out
<file>` was supplied, also write the same JSON atomically:

```
tmp="$file.tmp.$$"
jq . > "$tmp" <<< "$response"
mv "$tmp" "$file"
```

(Atomic write per NFR-4.)

### 5.2 Human summary (6–12 lines)

```
Harness Eval — <target absolute path>
Total: <total>/20
  Persona:       <n>/5 — <first sentence of rationales.persona>
  Capabilities:  <n>/5 — <first sentence of rationales.capabilities>
  Runtime:       <n>/5 — <first sentence of rationales.runtime>
  Meta-Gov:      <n>/5 — <first sentence of rationales.meta_gov>
kb_manifest_hash:   <hash>
evaluator_model_id: <model>
timestamp:          <iso8601>
```

Optionally append (lines 9–12) a "Lowest axis" callout:

```
Lowest axis: Runtime (1/5). Improve via /meta-harness:improve.
```

(Lines 9–12 are reserved for the lowest-axis observation; never prescribe a
specific fix here — that's the `harness-improve` skill's role.)

---

## AC-6 — reproducibility verification (operator runs this, not the skill)

AC-6 requires that 3 consecutive runs against the same KB + same project
input produce per-axis scores with `range (max - min) ≤ 2`, and total range
≤ 2. This is verified by the **operator** outside the skill; the skill itself
does not loop. Document the procedure here so it is reproducible:

```bash
# Run 3 times, capture JSON to separate files.
for i in 1 2 3; do
  /meta-harness:evaluate --json-only --raw-out "/tmp/eval-$i.json"
done

# Compute per-axis range and total range.
jq -s '
  {
    persona_range:      ([.[].persona]      | max - min),
    capabilities_range: ([.[].capabilities] | max - min),
    runtime_range:      ([.[].runtime]      | max - min),
    meta_gov_range:     ([.[].meta_gov]     | max - min),
    total_range:        ([.[].total]        | max - min)
  }
' /tmp/eval-1.json /tmp/eval-2.json /tmp/eval-3.json
```

PASS condition: every range value in the output is `≤ 2`.

Aggregation rule (so 3 runs of the same input agree as much as possible):
each axis is scored by 5 criteria from KB-3, averaged, then rounded
**half-to-even** (banker's rounding) — per KB-3's Aggregation section and
the AK-M1-1 fix.

---

## Failure modes summary

| Condition | Behavior |
|-----------|----------|
| Cwd is `/`, `$HOME`, or `/tmp` | `EVAL_CWD_REJECTED` on stderr, exit non-zero, do not invoke evaluator. |
| Target directory absent | `EVAL_CWD_REJECTED missing` on stderr. |
| KB file at `docs/theory/*.md` missing or empty | `EVAL_KB_MISSING <path>` on stderr. Fail-closed per FR-4. |
| Denylisted file slipped past the input filter (defensive output scan finds it) | `EVAL_DENYLIST_LEAKED` on stderr, do not show the user the response, log the leaked path. |
| Evaluator response is not strict JSON, or fails validator | First failure → retry once. Second failure → `EVAL_INVALID_JSON` on stderr. |
| Token budget exceeds ~200K input | Warning on stderr; do NOT abort (NFR-2 is advisory in v1, F2 deferred). |
| `evaluator_model_id` could not be captured from env/state | Use literal `claude-unknown`, warn on stderr. |

---

## Invariants this skill enforces

1. The rubric (KB-3) is the only source of scoring authority. Target project
   files are evaluation input only (HR-1).
2. Denylist-matched files are dropped at input AND defensively scanned at
   output (HR-4).
3. KB manifest hash is real, never the placeholder. Same for
   `evaluator_model_id` (HR-2).
4. Strict JSON or nothing — no partial / soft success rendering.
5. Atomic writes for `--raw-out` (NFR-4).
6. The skill never edits files in the target project. Editing is the
   `harness-build` / `harness-improve` skills' concern, never this one.
