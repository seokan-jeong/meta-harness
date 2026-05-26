#!/usr/bin/env bash
# validate-eval-output.sh
# ---
# Strict-validates a karpathy-evaluator JSON output against the schema in
# agents/karpathy-evaluator.md. Exits 0 on PASS, non-zero on first FAIL with
# the failed check name on stderr.
#
# Usage:
#   scripts/validate-eval-output.sh eval-output.json
#   scripts/validate-eval-output.sh < eval-output.json
#
# Checks (in order):
#   c01_parseable                 JSON parses with jq.
#   c02_required_fields           persona, capabilities, runtime, meta_gov,
#                                 total, rationales, kb_citations,
#                                 kb_manifest_hash, evaluator_model_id,
#                                 timestamp.
#   c03_axis_int_range            each axis score is integer in [0, 5].
#   c04_total_int_range           total is integer in [0, 20].
#   c05_total_equals_sum          total == persona+capabilities+runtime+meta_gov.
#   c06_rationales_4_keys         rationales has the 4 expected keys, no more.
#   c07_rationale_len_80          each rationale >= 80 characters (decoded).
#   c08_rationale_criterion_ids   each rationale matches its axis regex
#                                 (PER-[1-5] / CAP-[1-5] / RUN-[1-5] / MG-[1-5]).
#   c09_kb_citations_min_4        kb_citations is an array, length >= 4.
#   c10_kb_citations_per_axis     at least one citation per axis (persona,
#                                 capabilities, runtime, meta_gov).
#   c11_kb_manifest_hash_real     non-empty, not the placeholder.
#   c12_evaluator_model_id_real   non-empty, not the placeholder.
#   c13_timestamp_iso8601         matches ISO-8601 UTC regex.
#
# Exit codes:
#   0  — all checks pass.
#   1  — usage / argument error.
#   2  — c01_parseable failed.
#   3  — any cNN check >= c02 failed (first failure name on stderr).
#   4  — jq not available.

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

usage() {
  cat <<EOF
$SCRIPT_NAME — strict-validate a karpathy-evaluator JSON output.

Usage:
  $SCRIPT_NAME <file>
  $SCRIPT_NAME < <file>

Reports the first failed check on stderr with format:
  FAIL <check_id> <detail>
EOF
}

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "$SCRIPT_NAME: ERROR: 'jq' is required but not found in PATH" >&2
  exit 4
fi

# Read input from arg or stdin.
if [[ $# -ge 1 ]]; then
  if [[ ! -f "$1" ]]; then
    echo "$SCRIPT_NAME: ERROR: input file not found: $1" >&2
    exit 1
  fi
  input=$(cat "$1")
else
  input=$(cat)
fi

if [[ -z "$input" ]]; then
  echo "$SCRIPT_NAME: ERROR: empty input" >&2
  exit 2
fi

fail() {
  local check="$1"
  shift
  echo "FAIL $check $*" >&2
  exit 3
}

# ---------- c01: parseable ----------
if ! echo "$input" | jq -e . >/dev/null 2>&1; then
  echo "FAIL c01_parseable not_valid_json" >&2
  exit 2
fi

# ---------- c02: required top-level fields ----------
required_fields=(persona capabilities runtime meta_gov total rationales kb_citations kb_manifest_hash evaluator_model_id timestamp)
for field in "${required_fields[@]}"; do
  if ! echo "$input" | jq -e --arg f "$field" 'has($f) and (.[$f] != null)' >/dev/null 2>&1; then
    fail "c02_required_fields" "missing_or_null:$field"
  fi
done

# ---------- c03: axis scores integer in [0,5] ----------
for axis in persona capabilities runtime meta_gov; do
  if ! echo "$input" | jq -e --arg a "$axis" '
    (.[$a]) as $v
    | ($v | type) == "number" and ($v | floor) == $v and $v >= 0 and $v <= 5
  ' >/dev/null 2>&1; then
    fail "c03_axis_int_range" "axis:$axis"
  fi
done

# ---------- c04: total integer in [0,20] ----------
if ! echo "$input" | jq -e '
  (.total) as $t
  | ($t | type) == "number" and ($t | floor) == $t and $t >= 0 and $t <= 20
' >/dev/null 2>&1; then
  fail "c04_total_int_range" "total_out_of_range"
fi

# ---------- c05: total = sum of axes ----------
if ! echo "$input" | jq -e '
  .total == (.persona + .capabilities + .runtime + .meta_gov)
' >/dev/null 2>&1; then
  fail "c05_total_equals_sum" "total!=sum_of_axes"
fi

# ---------- c06: rationales has exactly 4 keys ----------
if ! echo "$input" | jq -e '
  (.rationales | type) == "object"
  and (.rationales | keys | sort) == ["capabilities","meta_gov","persona","runtime"]
' >/dev/null 2>&1; then
  fail "c06_rationales_4_keys" "rationales_keys_mismatch"
fi

# ---------- c07: each rationale >= 80 chars (after JSON decode) ----------
for axis in persona capabilities runtime meta_gov; do
  rationale=$(echo "$input" | jq -r --arg a "$axis" '.rationales[$a]')
  if [[ -z "$rationale" || "$rationale" == "null" ]]; then
    fail "c07_rationale_len_80" "axis:$axis:empty"
  fi
  # Use awk to count characters (multibyte-safe enough for our ASCII rubric).
  len=${#rationale}
  if (( len < 80 )); then
    fail "c07_rationale_len_80" "axis:$axis:len=$len"
  fi
done

# ---------- c08: each rationale cites its axis's criterion-ID ----------
check_regex() {
  local axis="$1"
  local re="$2"
  local rationale
  rationale=$(echo "$input" | jq -r --arg a "$axis" '.rationales[$a]')
  if ! echo "$rationale" | grep -E -q "$re"; then
    fail "c08_rationale_criterion_ids" "axis:$axis:no_match:$re"
  fi
}

check_regex "persona"      'PER-[1-5]'
check_regex "capabilities" 'CAP-[1-5]'
check_regex "runtime"      'RUN-[1-5]'
check_regex "meta_gov"     'MG-[1-5]'

# ---------- c09: kb_citations array length >= 4 ----------
if ! echo "$input" | jq -e '
  (.kb_citations | type) == "array" and (.kb_citations | length) >= 4
' >/dev/null 2>&1; then
  fail "c09_kb_citations_min_4" "kb_citations_too_short"
fi

# ---------- c10: at least one citation per axis ----------
for axis in persona capabilities runtime meta_gov; do
  if ! echo "$input" | jq -e --arg a "$axis" '
    .kb_citations | map(select(.axis == $a)) | length >= 1
  ' >/dev/null 2>&1; then
    fail "c10_kb_citations_per_axis" "axis:$axis:no_citation"
  fi
done

# ---------- c11: kb_manifest_hash non-empty + not placeholder ----------
kmh=$(echo "$input" | jq -r '.kb_manifest_hash // ""')
if [[ -z "$kmh" || "$kmh" == "null" || "$kmh" == "PLACEHOLDER_TO_BE_COMPUTED" ]]; then
  fail "c11_kb_manifest_hash_real" "value=$kmh"
fi

# ---------- c12: evaluator_model_id non-empty + not placeholder ----------
emi=$(echo "$input" | jq -r '.evaluator_model_id // ""')
if [[ -z "$emi" || "$emi" == "null" || "$emi" == "PLACEHOLDER_TO_BE_COMPUTED" ]]; then
  fail "c12_evaluator_model_id_real" "value=$emi"
fi

# ---------- c13: timestamp ISO-8601 UTC ----------
ts=$(echo "$input" | jq -r '.timestamp // ""')
# Accept YYYY-MM-DDTHH:MM:SS(.fff)?Z form.
if ! echo "$ts" | grep -E -q '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$'; then
  fail "c13_timestamp_iso8601" "value=$ts"
fi

echo "PASS all_checks (13/13)"
exit 0
