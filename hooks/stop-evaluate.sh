#!/usr/bin/env bash
# meta-harness Stop hook — opt-in evaluate.
#
# Default-OFF per ADR-0003. To activate, copy this hook's entry from
# hooks/hooks.json into your own .claude/settings.json. This hook is
# more impactful than session-start-healthcheck — it triggers an LLM-as-judge
# evaluation run that can take 30-120s and is billable. Keep it OFF unless
# you actually want that on every Stop.
#
# Behavior: when the current directory contains a meta-harness-built harness,
# run `/meta-harness:evaluate --json-only` and store the JSON report
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
    && { [ -f "${target}/CLAUDE.md" ] \
         || [ -f "${target}/.claude/agents/project-fit-analyzer.md" ] \
         || [ -f "${target}/agents/project-fit-analyzer.md" ]; }
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

# Evaluate exposes neither --write-report nor --silent (both are manage-only
# flags), so we capture output via the > redirect below. --json-only
# suppresses the human summary, leaving only the strict JSON document.
# --single pins the one-pass analyzer (ADR-0006): since v3.0.0 evaluate
# defaults to a ~5-pass debate panel, and a panel on every Stop is a cost
# footgun. (--json-only also implies --single, but we pin it explicitly.)
claude /meta-harness:evaluate \
  --target "${target}" \
  --single \
  --json-only \
  > "${out}"
