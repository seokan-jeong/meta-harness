---
adr_id: ADR-0003
title: Slash Commands as Primary Entrypoint with Opt-in Hooks
status: Accepted
date: "2026-05-26"
related_requirements: [FR-6, HR-3, NFR-5, R-6]
---

# ADR-0003: Slash Commands as Primary Entrypoint with Opt-in Hooks

## Context

meta-harness's four verbs (build / manage / improve / evaluate) need a user-facing entrypoint. Claude Code offers two:

- **Slash commands** (`/meta-harness:evaluate`) — explicitly invoked by the user.
- **Hooks** (`SessionStart`, `Stop`, `PreToolUse`, etc.) — triggered automatically by the Claude Code runtime.

The entrypoint choice affects:

- **User intent** — explicit invocation vs background automation
- **Cost control** — automatic runs can incur cost the user did not consciously authorize
- **Path safety (HR-3, R-6)** — automatic runs make cwd guard enforcement harder
- **User experience** — manual invocation each time vs background monitoring

The product brief selects "slash + opt-in hook hybrid" as the entrypoint model (FR-6). This ADR records the trade-offs and the concrete operating model.

## Options Considered

### Option A — Slash-only

Four slash commands. No hook support.

- Pros: simple. User intent is always explicit. HR-3 cwd guard can run on every invocation.
- Cons:
  - Drift detection depends on the user's memory — if the KB updates, the user has to remember to run manage
  - "Background healthcheck" workflows are impossible

### Option B — Hook-only (automatic triggers)

`evaluate` runs on `SessionStart` and/or `Stop` automatically.

- Pros: zero user friction. Scores always fresh.
- Cons:
  - **Cost runaway risk** — `evaluate` runs every session without the user noticing (R-4 directly)
  - **Path misidentification (HR-3, R-6)** — automatic runs have no natural moment to prompt for cwd confirmation
  - **User-intent violation** — clashes with "I just want to write code right now"
  - Debugging complexity — hooks make trigger origins hard to trace

### Option C — Slash + opt-in hook hybrid (CHOSEN)

The four slash commands are the primary entrypoint. Hooks ship but default to `enabled: false`; users must explicitly opt in.

- Pros:
  - Default behavior is safe — user intent preserved, HR-3 guard runs naturally
  - Power users can opt in to automation — team workflows (e.g. `SessionStart` healthcheck) are possible
  - Hooks and slash commands invoke the **same evaluator agent**, so output is identically shaped
  - Cost runaway only occurs when explicitly elected
- Cons:
  - Default-OFF hooks suffer from discoverability — "there but invisible"
  - Hook calls are non-interactive — no opportunity to prompt for confirmation; safety relies on output masking and secret guards
  - Both entrypoints must consistently enforce cwd guard, secret guard, output masking (DRY burden)

### Option D — Schedule (cron-like)

A separate scheduler invokes evaluate periodically.

- Pros: time-series tracking
- Cons:
  - Claude Code has no native scheduler — would require external cron + CLI
  - "Harness score time-series dashboard" is already deferred to v2
  - Outside this ADR's scope

## Decision

**Option C (slash + opt-in hook hybrid) is adopted.**

Operating model:

### Primary entrypoints (always available)

- `/meta-harness:build` — `commands/build.md`
- `/meta-harness:manage` — `commands/manage.md`
- `/meta-harness:improve` — `commands/improve.md`
- `/meta-harness:evaluate` — `commands/evaluate.md`

Each slash command, when invoked:

1. Displays the current cwd (HR-3 step 1)
2. Checks for `.claude/` or `CLAUDE.md` (HR-3 step 2)
3. Prompts for confirmation if absent (HR-3 step 3)
4. Requires explicit consent before creating new directories (HR-3 step 4)

### Opt-in hooks (default OFF)

- `hooks/hooks.json` registers two hooks, both `enabled: false` by default:
  - `SessionStart` → `hooks/session-start-healthcheck.sh` → `/meta-harness:manage --silent`
  - `Stop` → `hooks/stop-evaluate.sh` → `/meta-harness:evaluate --silent`
- Users enable hooks by editing `hooks/hooks.json` (or the project's `.claude/settings.json`) to set `enabled: true`.
- Hooks are non-interactive, so cwd confirmation is replaced by **fail-closed** behavior: a hook that cannot satisfy the cwd guard exits immediately and writes the reason to stderr.
- Hook output is written to `.meta-harness/reports/<timestamp>.json` inside the target project (PR-4 mitigation). The directory is auto-created on first hook run.

### Shared core

- Slash commands and hooks invoke the **same evaluator agent** (`agents/karpathy-evaluator.md`).
- The result JSON schema is identical across both entrypoints (the AC-2 schema).
- Shared workflow logic lives in the skill files (`skills/harness-evaluate/SKILL.md`, etc.). Commands and hooks both reference the skill — guard logic is not duplicated.

## Consequences

### Positive

- Default is safe — new users see only slash commands, and every invocation runs through HR-3
- Power users opt in — teams can automate workflows via hooks
- Identical evaluation output from both entrypoints — audit consistency
- README messaging stays simple: "just run `/meta-harness:evaluate`"

### Negative

- Default-OFF hooks lose discoverability. Mitigation: README has an "Advanced: enable opt-in hooks" section; CHANGELOG tracks hook spec changes.
- Both entrypoints must enforce cwd guard, secret guard, output masking consistently. Mitigation: guards live in the skill files as single sources of truth, referenced by both command and hook.
- Fail-closed hooks may silently exit, leaving the user wondering why automation isn't running. Mitigation: hook failures are logged both to stderr and as fail-reports under `.meta-harness/reports/`.

### Neutral

- v1 supports only two hook events (`SessionStart`, `Stop`). Other events (`PreToolUse`, `UserPromptSubmit`, etc.) deferred to v2.

## Future Work (v2 candidates)

- Diversify hook events (`PreToolUse`, etc.)
- Option for hooks to forward results into git diff or CI
- An onboarding wizard for enabling hooks (compensates for default-OFF discoverability)
- A unified dashboard tracking slash vs hook invocations and scores over time (pairs with the v2 time-series dashboard from out-of-scope)
