#!/usr/bin/env bash
# meta-harness SessionStart hook — opt-in healthcheck.
#
# Default-OFF per ADR-0003. Set hooks/hooks.json `session-start-healthcheck`
# entry's `enabled: true` (in the user's local clone) to activate.
#
# Behavior: when the current directory contains a meta-harness-built harness
# (signal: `.meta-harness/` dir MUST exist AND at least one of `CLAUDE.md` or
# `.claude/agents/project-fit-analyzer.md` (or the legacy top-level
# `agents/project-fit-analyzer.md`) is present — see AK-M6-4 rationale), run
# `/meta-harness:manage --json-only --silent --write-report` against the cwd
# and store the JSON report under `.meta-harness/reports/`. Otherwise exit 0
# silently — this hook MUST NOT add noise on machines that don't have
# meta-harness deployed yet. AND-stricter logic prevents the hook firing on
# vanilla projects that happen to have a hand-written CLAUDE.md.
#
# Failure modes:
#   - cwd is not a harnessed directory → exit 0 (silent skip).
#   - meta-harness manage command is not reachable → exit 0 (silent skip).
#     Rationale: a SessionStart hook that errors on missing tooling is more
#     disruptive than one that no-ops; the user opted in expecting healthcheck,
#     not a failed shell.
#   - manage itself returns non-zero → propagate the exit code to surface real
#     problems (KB drift miscompute, malformed harness, etc.).
#
# This hook never modifies the harness, never writes outside
# `.meta-harness/reports/`, and never prompts.

set -u

target="${PWD}"

# Harness-presence heuristic. `.meta-harness/` is the canonical signal (only
# created by /meta-harness:build); we additionally require at least one of
# the harness body files so a stray `.meta-harness/` directory alone (e.g.,
# leftover from a partial build) does not trigger the hook.
is_harnessed() {
  [ -d "${target}/.meta-harness" ] \
    && { [ -f "${target}/CLAUDE.md" ] \
         || [ -f "${target}/.claude/agents/project-fit-analyzer.md" ] \
         || [ -f "${target}/agents/project-fit-analyzer.md" ]; }
}

if ! is_harnessed; then
  exit 0
fi

# Locate the manage command via the plugin runtime. The exact invocation
# pattern depends on the Claude Code build:
#   - If `claude` CLI is on PATH and supports plugin commands directly:
#       claude /meta-harness:manage ...
#   - Otherwise the user is running an older runtime that doesn't expose
#     plugin slash commands from a non-interactive shell; we skip silently.
#
# This script does NOT try to vendor the manage logic in bash — manage.md
# delegates to skills/harness-manage/SKILL.md which delegates to plugin
# runtime tools (Read/Glob/Grep/Bash); replicating that here would drift.
if ! command -v claude >/dev/null 2>&1; then
  exit 0
fi

reports_dir="${target}/.meta-harness/reports"
mkdir -p "${reports_dir}" 2>/dev/null || {
  # Silent skip for the no-harness case is the default; for permission
  # failure on an opted-in hook, emit a single stderr breadcrumb so the
  # operator can diagnose without violating the no-stdout-noise policy.
  echo "[meta-harness:hook] cannot create ${reports_dir} (permission denied); skipping" >&2
  exit 0
}

ts="$(date -u +%Y%m%dT%H%M%SZ)"
out="${reports_dir}/${ts}-manage.json"

# Hand off. --silent suppresses stdout; --write-report does the actual save.
# Exit code from claude (and through it, manage) is what we propagate.
claude /meta-harness:manage \
  --target "${target}" \
  --json-only --silent \
  --write-report "${out}"
