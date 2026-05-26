#!/usr/bin/env bash
# meta-harness Stop hook — opt-in evaluate.
#
# Default-OFF per ADR-0003. Set hooks/hooks.json `stop-evaluate` entry's
# `enabled: true` (in the user's local clone) to activate. This hook is
# more impactful than session-start-healthcheck — it triggers an LLM-as-judge
# evaluation run that can take 30-120s and is billable. Keep it OFF unless
# you actually want that on every Stop.
#
# Behavior: when the current directory contains a meta-harness-built harness,
# run `/meta-harness:evaluate --json-only --silent` and store the JSON report
# under `.meta-harness/reports/`. Otherwise exit 0 silently.
#
# Same silent-skip-on-missing-tooling policy as session-start-healthcheck.

set -u

target="${PWD}"

# Harness-presence heuristic — same AND-stricter logic as session-start-healthcheck.
# `.meta-harness/` is canonical (created only by /meta-harness:build); pair
# with at least one harness body file to filter out stray directories.
is_harnessed() {
  [ -d "${target}/.meta-harness" ] \
    && { [ -f "${target}/CLAUDE.md" ] || [ -f "${target}/agents/karpathy-evaluator.md" ]; }
}

if ! is_harnessed; then
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  exit 0
fi

reports_dir="${target}/.meta-harness/reports"
mkdir -p "${reports_dir}" 2>/dev/null || {
  echo "[meta-harness:hook] cannot create ${reports_dir} (permission denied); skipping" >&2
  exit 0
}

ts="$(date -u +%Y%m%dT%H%M%SZ)"
out="${reports_dir}/${ts}-evaluate.json"

# Evaluate doesn't yet expose --write-report (that's a manage-only flag), so
# we redirect stdout. --json-only suppresses the human summary. --silent is
# not a documented evaluate flag in v0.1.0; if your build's evaluate doesn't
# accept it, drop it without harm (the > redirect already handles stdout).
claude /meta-harness:evaluate \
  --target "${target}" \
  --json-only \
  > "${out}"
