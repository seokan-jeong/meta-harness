---
skill_id: harness-build
name: Harness Build Workflow
description: "Procedural workflow for /meta-harness:build. Resolves template variables, plans a create/skip/conflict write set, surfaces a diff for user approval, performs atomic writes with snapshot rollback, then runs the AC-1 9-path verification check."
invoked_by:
  - commands/build.md
invokes: []
related_requirements: [FR-1, NFR-4, HR-3, AC-1, AC-8]
related_adrs: [ADR-0001, ADR-0003]
milestone: M3
---

# Harness Build — workflow skill

This skill is the **single source of truth** for the `/meta-harness:build`
procedure. The slash command (`commands/build.md`) is a thin trigger that
runs the cwd guard prompt and then hands off here.

The skill writes files into the target project. It does NOT modify files in
the `meta-harness` plugin itself (other than possibly running
`scripts/build-kb-manifest.sh` to resolve placeholder hashes — that script is
already atomic).

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Target project root | `--target <path>` arg, else `$PWD` | Yes |
| Template tree | `templates/{persona,capabilities,runtime,meta-gov}/**/*.tpl` (relative to the plugin install root) | Yes |
| KB manifest | `docs/kb-manifest.json` in the plugin install root | Yes (fail-closed if absent — `BUILD_KB_MISSING`) |
| `--dry-run` flag | argv | No |
| `--accept-all` flag | argv | No |

---

## Outputs

On success, exactly 9 paths under the target (AC-1 set; see Step 5). On any
failure (including a user decline), the target directory's file set is
unchanged from before the build.

A `.meta-harness/.snapshot/<UTC>/` directory is also written under the target
when at least one path was an overwrite (not for pure-creates). That snapshot
is what makes Step 4 rollback total.

---

## Step 0 — Pre-flight (HR-3, AC-8)

Before any other work:

1. Resolve the target. If argv looks like `--target <path>`, use that;
   otherwise use `$PWD`.
2. **Resolve symlinks portably** before comparing. Use `pwd -P` after `cd`:
   ```bash
   resolved=$(cd "$target" 2>/dev/null && pwd -P)
   ```
   POSIX; works on macOS (where default `readlink` lacks `-f`) and Linux.
   This mirrors the M2 fix in `harness-evaluate`'s skill.
3. **Reject** the resolved target if any of:
   - Path equals `/`
   - Path equals `$HOME` (exactly)
   - Path equals `/tmp` or `/private/tmp`
   - Path does not exist or is not a directory
   On rejection: emit `BUILD_CWD_REJECTED <reason>` on stderr, exit non-zero.
   No files written.
4. **Print** the cwd, then ask the project-root confirmation prompt:
   ```
   cwd: <resolved absolute path>
   Treat this directory as the project root? [y/N]
   ```
   Default is **N**. If the user enters anything other than `y` or `Y`,
   emit `BUILD_CWD_REJECTED user_declined_root` on stderr and exit non-zero.
   The `--accept-all` flag bypasses this prompt; the skill logs
   `accept_all: skipping_root_prompt` to stderr in that case.

This step is the FIRST AC-8 gate. As long as Steps 4–5 are unreachable when
this step exits non-zero, AC-8 holds for the root-decline case.

---

## Step 1 — Resolve template variables

### Plugin install root resolution

Throughout this skill, `<plugin_root>` is the directory that contains the
plugin's own `.claude-plugin/plugin.json` (i.e., where `meta-harness` itself
is installed — NOT the target project). The Claude Code runtime is expected
to expose this as `$CLAUDE_PLUGIN_ROOT` (or equivalent — naming may differ
across plugin host versions); if that env var is unset, derive it as the
directory two levels above this SKILL.md:
`plugin_root="$(cd "$(dirname "$0")/../.." && pwd -P)"`. The boundary
between `<plugin_root>` (read-only, source of templates + KB) and
`$resolved` (write target, the user's project) is load-bearing — never
swap them.

Compute the four whitelisted placeholders:

| Placeholder | Source |
|-------------|--------|
| `{{project_name}}` | `basename "$resolved"` |
| `{{kb_set_version}}` | `jq -r '.kb_set_version' <plugin_root>/docs/kb-manifest.json` |
| `{{kb_manifest_hash}}` | `jq -r '.combined_hash' <plugin_root>/docs/kb-manifest.json` |
| `{{generated_at}}` | `date -u +%Y-%m-%dT%H:%M:%SZ` |

### Defense in depth: real hashes, not placeholders

If `docs/kb-manifest.json`'s `combined_hash` is the literal string
`PLACEHOLDER_TO_BE_COMPUTED` (or empty, or starts with `PLACEHOLDER_`), the
skill MUST run `scripts/build-kb-manifest.sh` first and re-read the manifest.
A vendored evaluator that ships with a placeholder hash is worthless — it
will produce non-reproducible scores. If after running the script the value
is still missing, fail-closed with `BUILD_KB_MISSING combined_hash` on stderr.

The same fail-closed rule applies if any KB file in the manifest's `entries`
array does not exist on disk: emit `BUILD_KB_MISSING <path>` and exit
non-zero.

---

## Step 2 — Plan the write set

Walk the template tree and compute the destination for each `.tpl` file. The
mapping rule is:

| Template source (relative to plugin root) | Destination (relative to target) |
|-------------------------------------------|----------------------------------|
| `templates/persona/CLAUDE.md.tpl` | `CLAUDE.md` |
| `templates/persona/agents/karpathy-evaluator.md.tpl` | `agents/karpathy-evaluator.md` |
| `templates/capabilities/skills/example-skill/SKILL.md.tpl` | `skills/example-skill/SKILL.md` |
| `templates/capabilities/commands/example-command.md.tpl` | `commands/example-command.md` |
| `templates/runtime/.claude/settings.json.tpl` | `.claude/settings.json` |
| `templates/runtime/hooks/example-hook.sh.tpl` | `hooks/example-hook.sh` |
| `templates/runtime/hooks/hooks.json.tpl` | `hooks/hooks.json` |
| `templates/meta-gov/README.md.tpl` | `README.md` |
| `templates/meta-gov/CHANGELOG.md.tpl` | `CHANGELOG.md` |
| `templates/meta-gov/docs/ADR-NNNN.md.tpl` | `docs/ADR-NNNN.md` |
| `templates/meta-gov/docs/ADR-0001-static-kb-choice.md.tpl` | `docs/ADR-0001-static-kb-choice.md` |

For each (src, dest) pair:

1. Substitute the four placeholders into the template body (in memory; do not
   write yet).
2. Classify dest as:
   - **create** — `dest` does not exist on disk.
   - **skip** — `dest` exists AND its content is byte-identical to the
     substituted template body.
   - **conflict** — `dest` exists AND its content differs from the
     substituted template body.

Skipping byte-identical files is what makes a re-run of `/meta-harness:build`
against an already-built directory a no-op (idempotency).

---

## Step 3 — Show diff and ask "Apply these changes? [y/N]"

This is the SECOND AC-8 gate. Format:

```
Planned writes for <resolved target>:

  Action     | Destination                                  | Note
  -----------+----------------------------------------------+---------------------------
  create     | CLAUDE.md                                    | New file
  create     | agents/karpathy-evaluator.md                 | New file
  conflict   | README.md                                    | Differs from template; will overwrite (snapshot taken)
  skip       | docs/ADR-0001-static-kb-choice.md            | Byte-identical
  ...

Apply these changes? [y/N]
```

For each **conflict** entry, append a unified diff capped at 30 lines below
the table (use `diff -u <dest> <(printf "%s" "$body")` and `head -n 30`).

If the user answers anything other than `y` or `Y`:
- If the set contained any conflicts: emit `BUILD_CONFLICT_DECLINED` on
  stderr and exit non-zero.
- Otherwise: emit `BUILD_USER_DECLINED` on stderr and exit non-zero.

In **both** decline cases, NO file has been written yet — Step 4 has not run.

The `--accept-all` flag bypasses this prompt; the skill logs
`accept_all: skipping_apply_prompt` and proceeds to Step 4.

The `--dry-run` flag exits with code 0 here, before Step 4.

---

## Step 4 — Atomic write with snapshot rollback (NFR-4)

This is the **only step in the skill that touches disk**. Reaching this step
requires:
- Step 0's project-root prompt returned `y` (or `--accept-all`).
- Step 3's apply prompt returned `y` (or `--accept-all`).
- `--dry-run` is NOT set.

### 4.1 Snapshot policy

If at least one entry in the write set is a **conflict** (not pure create /
skip), the skill first creates a snapshot directory:

```bash
snap="$resolved/.meta-harness/.snapshot/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$snap"
```

For every conflict entry, copy the about-to-be-overwritten file into the
snapshot, preserving its relative path inside `$snap`. Pure-create entries do
NOT consume snapshot slots (there is nothing to roll back to for them — if a
create fails, rollback means delete-the-new-file).

### 4.2 Per-file atomic write

For each entry classified as `create` or `conflict`:

```bash
mkdir -p "$(dirname "$dest")"
tmp="$dest.tmp.$$"
printf '%s' "$body" > "$tmp"
mv "$tmp" "$dest"
```

Track each `(action, dest)` pair in a running journal in memory.

If ANY single `mv` (or its preceding `printf`) fails, halt immediately and
go to Step 4.3.

### 4.3 Rollback contract

On any write failure:

1. For every entry the journal marks as `create` that has been written:
   `rm -f "$dest"`.
2. For every entry the journal marks as `conflict` that has been written:
   restore `$dest` from the snapshot.
3. Emit `BUILD_WRITE_FAILED <reason>` on stderr.
4. Exit non-zero.

**Rollback scope (honest disclosure)**: Step 4.2's `mkdir -p "$(dirname "$dest")"`
may have created empty parent directories (e.g., `agents/`, `skills/example-skill/`,
`.claude/`) before the write failed. Step 4.3 deletes the **files** but does
NOT remove those empty parent directories. The user-decline path (Step 0 N
or Step 3 N) is unaffected — those paths exit BEFORE Step 4.2 runs, so AC-8's
"ls -A unchanged" invariant holds for them. The partial-write rollback case
(NFR-4) is honest about leaving empty `mkdir`'d directories; an operator who
needs a strictly-pristine state may `find "$target" -type d -empty -delete`
after a rollback (idempotent and safe).

The skill does NOT delete the snapshot directory on failure — the operator
may want to inspect it. On success, the snapshot remains in place as a
record (it is a small write under `.meta-harness/`).

**Snapshot retention is the operator's responsibility.** The build does not
ship a `.gitignore` template (out of M3 scope). After a successful build,
Step 5 prints a one-line reminder: `Snapshot at <path>; consider adding
.meta-harness/ to .gitignore if this repo is git-tracked.`

### 4.4 Permissions

After writing `hooks/example-hook.sh`, `chmod +x` it so the hook is
executable if the user later flips `hooks.json` to enabled.

---

## Step 5 — Post-write verification (AC-1)

After Step 4 completes successfully, run the AC-1 9-path existence check
verbatim:

```bash
target="$resolved"

missing=0
for p in CLAUDE.md agents/karpathy-evaluator.md .claude/settings.json README.md CHANGELOG.md docs/ADR-0001-static-kb-choice.md; do
  test -f "$target/$p" || { echo "MISSING: $p" >&2; missing=1; }
done
find "$target/skills" -name SKILL.md 2>/dev/null | head -1 | grep -q . || { echo "MISSING: skills/*/SKILL.md" >&2; missing=1; }
find "$target/commands" -name "*.md" 2>/dev/null | head -1 | grep -q . || { echo "MISSING: commands/*.md" >&2; missing=1; }
find "$target/hooks" -type f 2>/dev/null | head -1 | grep -q . || { echo "MISSING: hooks/*" >&2; missing=1; }

if [ "$missing" -ne 0 ]; then
  echo "BUILD_VERIFICATION_FAILED" >&2
  exit 1
fi
```

If any of the 9 slots is missing, surface `BUILD_VERIFICATION_FAILED` on
stderr and exit non-zero. (This is a defensive check; if Step 4 was atomic
and the journal was complete, this should never fire — but a defensive
verification step is exactly what MG-5 / AC-1 reward.)

On success, emit the human summary:

```
Harness Build — <resolved target>
Wrote N new files, overwrote M existing files, skipped K byte-identical files.
KB set version: <kb_set_version>
KB manifest hash: <kb_manifest_hash>
Snapshot (if any): <snap path>
Next: run /meta-harness:evaluate to score the new harness.
```

---

## `--dry-run` mode

When `--dry-run` is set:

- Run Step 0 (including the project-root prompt; the prompt result still
  matters because dry-run should not preview against a rejected cwd).
- Run Step 1 (resolve variables).
- Run Step 2 (classify each target as create / skip / conflict).
- Run Step 3 (show the diff). Exit code 0 instead of asking for approval, OR
  ask the prompt and treat the answer purely as "would I have proceeded?"
  signal (implementation choice; either is consistent with "no writes").
- SKIP Steps 4–5.
- Exit 0.

`--dry-run` is the operator's way to see the diff without ever touching
disk; `--dry-run --accept-all` is a no-op pair (the skill warns and exits
non-zero with `BUILD_BAD_ARGS`).

---

## AC-8 verification (paper-walk)

This skill satisfies AC-8 ("rejection leaves the directory untouched") by
the following construction:

- The **only step that writes to disk is Step 4**. Steps 0, 1, 2, 3, and
  Step 5 do not call any disk-mutating commands. Step 1's `date` and `jq`
  calls are pure reads. Step 2's classification is in-memory only. Step 3's
  diff rendering reads but does not write.
- **Step 4 is reachable only if both**:
  - Step 0's `Treat this directory as the project root? [y/N]` returned `y`
    or `Y` (or `--accept-all` is set), AND
  - Step 3's `Apply these changes? [y/N]` returned `y` or `Y` (or
    `--accept-all` is set), AND
  - `--dry-run` is NOT set.
- Therefore, if the user answers `N` (or the default) at EITHER prompt,
  Step 4 never runs, no `printf > .tmp.$$` ever fires, no `mv` ever fires,
  and no file inside `$resolved` is created or modified. A subsequent
  `ls -A "$resolved"` is byte-identical to the pre-build listing. This is
  exactly the AC-8 evidence.

The `--accept-all` flag is the one path that bypasses both gates. It is
documented in `commands/build.md`'s argument table as a CI / scripted-use
convenience, with the explicit caveat that it defeats the AC-8 user-approval
guarantee. Operators using `--accept-all` should run `--dry-run` first.

---

## Failure modes summary

| Code | Meaning | Disk state |
|------|---------|------------|
| `BUILD_CWD_REJECTED` | Step 0 refused the target (rejected path OR user declined). | Untouched. |
| `BUILD_USER_DECLINED` | Step 3 prompt returned `N` and no conflicts were in the set. | Untouched. |
| `BUILD_CONFLICT_DECLINED` | Step 3 prompt returned `N` and at least one entry was a conflict. | Untouched. |
| `BUILD_KB_MISSING <reason>` | Step 1 found the plugin's KB manifest absent, or a KB file referenced in it is missing on disk, or `combined_hash` was a placeholder and the rebuild did not fix it. | Untouched. |
| `BUILD_WRITE_FAILED <reason>` | Step 4 hit a write/rename failure. | Rolled back per Step 4.3 (created-this-run files deleted, overwritten files restored from snapshot). Snapshot directory retained for inspection. |
| `BUILD_VERIFICATION_FAILED` | Step 5 inline 9-path check found a missing slot after Step 4 claimed success. Indicates a bug; the operator should file an issue and inspect the snapshot. | The writes from this run are still on disk; the snapshot can be used to manually revert. |
| `BUILD_BAD_ARGS` | argv combination is contradictory (e.g., `--dry-run --accept-all`). | Untouched. |

---

## Invariants this skill enforces

1. No disk write happens before the user confirms both prompts (Step 0 and
   Step 3) — except under `--accept-all`, which the user opted into
   explicitly.
2. Every individual file write is atomic via `.tmp.$$` -> `mv` (NFR-4).
3. Any overwrite is backed up to `.meta-harness/.snapshot/<UTC>/` before the
   first write of the run; rollback restores from there.
4. The KB manifest hash baked into the generated `agents/karpathy-evaluator.md`
   and `README.md` is the real `combined_hash`, never the literal placeholder.
5. The skill never writes outside `$resolved`; it never modifies the
   `meta-harness` plugin's own files (other than allowing
   `scripts/build-kb-manifest.sh` to resolve the manifest, which is its
   designed behavior).
6. Step 5's verification is non-optional. If a build silently passed Step 4
   but Step 5 reports MISSING, the skill exits non-zero so the operator
   notices.
