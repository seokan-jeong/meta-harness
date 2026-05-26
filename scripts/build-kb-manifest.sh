#!/usr/bin/env bash
# build-kb-manifest.sh
# ---
# Resolves docs/kb-manifest.json: replaces every entry's "sha256" placeholder
# with the actual sha256 of the file at "path", and recomputes
# "combined_hash" as sha256 of the concatenation of per-entry hashes,
# ordered by lexicographic kb_id.
#
# Usage:
#   scripts/build-kb-manifest.sh              # use docs/kb-manifest.json
#   scripts/build-kb-manifest.sh <manifest>   # use a custom manifest path
#
# Exit codes:
#   0 — manifest resolved and written atomically
#   1 — usage / argument error
#   2 — manifest missing or unreadable
#   3 — referenced KB file missing or unreadable
#   4 — jq / shasum / sha256sum not available
#
# Portability:
#   macOS: uses /usr/bin/shasum -a 256
#   Linux: falls back to /usr/bin/sha256sum if shasum is absent
#
# Atomic write (NFR-4): the script writes to <manifest>.tmp then mv's into
# place. A crash mid-write never leaves a half-written manifest.

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

usage() {
  cat <<EOF
$SCRIPT_NAME — compute sha256 for each KB entry and the combined_hash.

Usage:
  $SCRIPT_NAME [manifest-path]

Defaults:
  manifest-path = docs/kb-manifest.json (relative to current working dir)

Exit codes:
  0 OK | 1 usage | 2 manifest missing | 3 KB file missing | 4 missing tool
EOF
}

# ---------- argument handling ----------

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  usage
  exit 0
fi

manifest="${1:-docs/kb-manifest.json}"

if [[ ! -f "$manifest" ]]; then
  echo "$SCRIPT_NAME: ERROR: manifest not found: $manifest" >&2
  exit 2
fi
if [[ ! -r "$manifest" ]]; then
  echo "$SCRIPT_NAME: ERROR: manifest not readable: $manifest" >&2
  exit 2
fi

# ---------- tool detection ----------

if ! command -v jq >/dev/null 2>&1; then
  echo "$SCRIPT_NAME: ERROR: 'jq' is required but not found in PATH" >&2
  exit 4
fi

sha256_cmd=""
if command -v shasum >/dev/null 2>&1; then
  sha256_cmd="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256_cmd="sha256sum"
else
  echo "$SCRIPT_NAME: ERROR: neither 'shasum' nor 'sha256sum' found" >&2
  exit 4
fi

# Compute sha256 of stdin or a file path; returns just the hex digest.
hash_file() {
  local path="$1"
  $sha256_cmd "$path" | awk '{print $1}'
}

hash_stdin() {
  $sha256_cmd | awk '{print $1}'
}

# ---------- manifest base directory ----------
# Entries' "path" fields are relative to the plugin root (which is the parent
# of `docs/`). We resolve the plugin root as the directory two levels above
# the manifest if it sits at docs/kb-manifest.json; otherwise as the manifest's
# own parent. The path inside the manifest is treated relative to plugin root.

manifest_dir="$(cd "$(dirname "$manifest")" && pwd)"
# If the manifest lives at .../docs/kb-manifest.json, the plugin root is one up.
if [[ "$(basename "$manifest_dir")" == "docs" ]]; then
  plugin_root="$(cd "$manifest_dir/.." && pwd)"
else
  plugin_root="$manifest_dir"
fi

# ---------- enumerate and hash entries ----------

# Pull entries sorted by kb_id (deterministic combined_hash order).
# Output: TSV "kb_id<TAB>relative_path"
sorted_entries=$(
  jq -r '
    .entries
    | sort_by(.kb_id)
    | .[]
    | [.kb_id, .path]
    | @tsv
  ' "$manifest"
)

if [[ -z "$sorted_entries" ]]; then
  echo "$SCRIPT_NAME: ERROR: manifest has no .entries[]" >&2
  exit 2
fi

# Build per-entry hash map (kb_id -> hash) and the concatenation buffer.
declare -a id_arr
declare -a hash_arr
combined_input=""

while IFS=$'\t' read -r kb_id rel_path; do
  if [[ -z "$kb_id" || -z "$rel_path" ]]; then
    continue
  fi
  abs_path="$plugin_root/$rel_path"
  if [[ ! -f "$abs_path" ]]; then
    echo "$SCRIPT_NAME: ERROR: KB file referenced by entry '$kb_id' not found: $abs_path" >&2
    exit 3
  fi
  digest=$(hash_file "$abs_path")
  if [[ -z "$digest" ]]; then
    echo "$SCRIPT_NAME: ERROR: failed to hash $abs_path" >&2
    exit 3
  fi
  id_arr+=("$kb_id")
  hash_arr+=("$digest")
  combined_input="${combined_input}${digest}"
done <<< "$sorted_entries"

if (( ${#id_arr[@]} == 0 )); then
  echo "$SCRIPT_NAME: ERROR: no entries produced any hash" >&2
  exit 2
fi

combined_hash="sha256:$(printf '%s' "$combined_input" | hash_stdin)"

# ---------- patch JSON ----------
# Build a jq filter that:
#   * walks .entries[] and, when a kb_id matches one in our map, swaps the
#     sha256 to our computed digest (prefixed with "sha256:" so downstream
#     consumers can disambiguate algo);
#   * sets .combined_hash to our combined value;
#   * refreshes .generated_at to now (UTC ISO-8601).

generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Build a JSON object map for jq lookup (pure bash; assemble with printf).
map_pairs=""
for i in "${!id_arr[@]}"; do
  if [[ -n "$map_pairs" ]]; then
    map_pairs="${map_pairs},"
  fi
  # Each entry: "kb_id":"sha256:<hex>"
  map_pairs="${map_pairs}\"${id_arr[$i]}\":\"sha256:${hash_arr[$i]}\""
done
hash_map="{${map_pairs}}"

tmp="${manifest}.tmp.$$"

jq \
  --argjson hashmap "$hash_map" \
  --arg combined "$combined_hash" \
  --arg generated_at "$generated_at" \
  '
    .generated_at = $generated_at
    | .entries |= map(
        if ($hashmap[.kb_id] // null) != null
        then .sha256 = $hashmap[.kb_id]
        else .
        end
      )
    | .combined_hash = $combined
  ' "$manifest" > "$tmp"

# Sanity check: the resulting JSON must still parse and not contain placeholder
# strings, otherwise abort before mv.
if ! jq -e . "$tmp" >/dev/null 2>&1; then
  echo "$SCRIPT_NAME: ERROR: produced manifest is not valid JSON; aborting" >&2
  rm -f "$tmp"
  exit 2
fi

if jq -e '
  ([.entries[].sha256] + [.combined_hash])
  | map(select(. == "PLACEHOLDER_TO_BE_COMPUTED"))
  | length > 0
' "$tmp" >/dev/null 2>&1; then
  echo "$SCRIPT_NAME: ERROR: produced manifest still contains PLACEHOLDER strings; aborting" >&2
  rm -f "$tmp"
  exit 2
fi

mv "$tmp" "$manifest"

echo "$SCRIPT_NAME: OK: $manifest updated (${#id_arr[@]} entries, combined_hash=$combined_hash)"
exit 0
