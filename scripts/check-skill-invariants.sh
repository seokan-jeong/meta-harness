#!/usr/bin/env bash
#
# check-skill-invariants.sh — maintainer/CI consistency linter for the
# meta-harness plugin's OWN files.
#
# WHY THIS EXISTS (see CLAUDE.md "F-003" / the project-fit-analyzer finding):
# The four workflow skills (harness-{build,evaluate,improve,manage}) are
# intentionally self-contained — each SKILL.md restates the shared safety
# invariants (HR-3 cwd guard, HR-4 secret denylist) so the Claude Code runtime
# can load any one of them in isolation. Self-containment is good for runtime
# but creates a maintenance hazard: edit the canonical copy in harness-evaluate
# and the restatements in build/manage can silently drift. There is no
# product skill to catch that (Invariant 6: the shipped skills refuse to edit
# the plugin's own files). This script is that missing consistency tooling.
#
# It also guards two adjacent invariants that have bitten releases before:
#   - related_adrs frontmatter must point at an ADR that actually ships under
#     docs/adr/ (the F-002 dangling-reference class), and
#   - the four version-sync points the release skill bumps must agree.
#
# Run from the repo root:  bash scripts/check-skill-invariants.sh
# Exit 0 = all invariants hold; exit 1 = at least one drift/violation.

set -uo pipefail
cd "$(dirname "$0")/.."

FAILS=0
note_fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILS=$((FAILS+1)); }
note_ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }

SKILLS=(skills/harness-*/SKILL.md)
COMMANDS=(commands/*.md)

# ---------------------------------------------------------------------------
# 1. HR-4 secret-denylist completeness.
#    Any file that enumerates the denylist (>= 2 of the 6 patterns present)
#    MUST contain all 6. A lone incidental mention (count 1) is ignored.
# ---------------------------------------------------------------------------
echo "[1] HR-4 denylist completeness (all 6 patterns where the list is enumerated)"
DENY_PATS=('\.env\*' 'id_rsa' '\*\.pem' '\*\.key' 'credentials\.' 'secrets\.')
DENY_LABEL=('.env*' 'id_rsa*' '*.pem' '*.key' 'credentials.*' 'secrets.*')
for f in "${SKILLS[@]}" "${COMMANDS[@]}" README.md; do
  [ -f "$f" ] || continue
  present=0; missing=""
  for i in "${!DENY_PATS[@]}"; do
    if grep -qE "${DENY_PATS[$i]}" "$f"; then present=$((present+1)); else missing="$missing ${DENY_LABEL[$i]}"; fi
  done
  if [ "$present" -ge 2 ] && [ "$present" -lt 6 ]; then
    note_fail "$f enumerates the denylist but is missing:$missing"
  fi
done
[ "$FAILS" -eq 0 ] && note_ok "denylist consistent wherever enumerated"

# ---------------------------------------------------------------------------
# 2. HR-3 cwd-guard blocked-path completeness.
#    Any skill/command that describes the cwd guard must reference all three
#    portable blocked paths ($HOME, /tmp, /private/tmp). "/" is unguardable by
#    grep (too generic) and is covered by the resolved-equals-root check in code.
# ---------------------------------------------------------------------------
echo "[2] HR-3 cwd-guard blocked paths (\$HOME, /tmp, /private/tmp together)"
before=$FAILS
for f in "${SKILLS[@]}" "${COMMANDS[@]}"; do
  [ -f "$f" ] || continue
  grep -qiE 'cwd guard|HR-3' "$f" || continue
  miss=""
  grep -qE '\$HOME|HOME' "$f"      || miss="$miss \$HOME"
  grep -qE '/tmp'        "$f"      || miss="$miss /tmp"
  grep -qE '/private/tmp' "$f"     || miss="$miss /private/tmp"
  [ -n "$miss" ] && note_fail "$f describes the cwd guard but omits blocked path(s):$miss"
done
[ "$FAILS" -eq "$before" ] && note_ok "cwd-guard blocked-path set consistent"

# ---------------------------------------------------------------------------
# 3. ADR reference integrity (guards the F-002 dangling-reference class).
#    Every ADR id named in any related_adrs: [...] frontmatter must resolve to
#    a real docs/adr/ADR-XXXX*.md file.
# ---------------------------------------------------------------------------
echo "[3] related_adrs reference integrity (each ADR ships under docs/adr/)"
before=$FAILS
referenced=$(grep -rhoE 'related_adrs: \[[^]]*\]' "${SKILLS[@]}" 2>/dev/null | grep -oE 'ADR-[0-9]+' | sort -u)
for adr in $referenced; do
  if ! ls docs/adr/${adr}-*.md >/dev/null 2>&1; then
    note_fail "related_adrs references ${adr}, but no docs/adr/${adr}-*.md exists (retired/dangling?)"
  fi
done
[ "$FAILS" -eq "$before" ] && note_ok "all related_adrs resolve to docs/adr/ (${referenced//$'\n'/, })"

# ---------------------------------------------------------------------------
# 4. Manifest JSON validity.
# ---------------------------------------------------------------------------
echo "[4] manifest JSON validity"
before=$FAILS
for j in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  if [ -f "$j" ]; then jq -e . "$j" >/dev/null 2>&1 || note_fail "$j is not valid JSON"; else note_fail "$j is missing"; fi
done
[ "$FAILS" -eq "$before" ] && note_ok "plugin.json, marketplace.json, hooks.json parse"

# ---------------------------------------------------------------------------
# 5. Version sync across the 4 release-bumped locations (per .claude/skills/release).
# ---------------------------------------------------------------------------
echo "[5] version sync (plugin.json == marketplace ref == hooks _plugin_version == README badge)"
before=$FAILS
pv=$(jq -r '.version' .claude-plugin/plugin.json 2>/dev/null)
mref=$(jq -r '.plugins[0].source.ref' .claude-plugin/marketplace.json 2>/dev/null); mv="${mref#v}"
hv=$(jq -r '._plugin_version // empty' hooks/hooks.json 2>/dev/null)
badge=$(grep -oE 'badge/plugin-v[0-9]+\.[0-9]+\.[0-9]+' README.md | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
if [ "$pv" = "$mv" ] && [ "$pv" = "$hv" ] && [ "$pv" = "$badge" ]; then
  note_ok "all four agree on v$pv"
else
  note_fail "version mismatch — plugin.json=$pv marketplace=$mv hooks=$hv README-badge=$badge"
fi

# ---------------------------------------------------------------------------
# 6. Required build templates exist on disk.
#    This set mirrors the BUILD_TEMPLATE_MISSING failure mode in
#    skills/harness-build/SKILL.md. It is the REQUIRED set, not every template
#    path the skill mentions: templates/persona/agents/project-fit-analyzer.md.tpl
#    is deliberately NOT listed — harness-build (≈ lines 113-115) explicitly does
#    NOT use it (the analyzer is copied verbatim from agents/project-fit-analyzer.md),
#    so asserting it would be a false positive.
# ---------------------------------------------------------------------------
echo "[6] required build templates present (per BUILD_TEMPLATE_MISSING)"
before=$FAILS
REQUIRED_TEMPLATES=(
  templates/persona/CLAUDE.md.tpl
  templates/capabilities/skills/_stub/SKILL.md.tpl
  templates/persona/agents/_stub.md.tpl
  templates/meta-gov/.meta-harness/.gitignore.tpl
)
for t in "${REQUIRED_TEMPLATES[@]}"; do
  [ -f "$t" ] || note_fail "required build template missing: $t"
done
[ "$FAILS" -eq "$before" ] && note_ok "all ${#REQUIRED_TEMPLATES[@]} required build templates present"

# ---------------------------------------------------------------------------
# 7. Internal evaluate callers pin --single (ADR-0006).
#    Since v3.0.0 `evaluate` defaults to the debate panel. Any caller that
#    invokes evaluation INTERNALLY must pin --single, or it would silently
#    trigger a ~5-pass panel and break AC-3 reproducibility (improve phase 4),
#    the HR-5 stagnation / regression ±1 band (improve), or the cost envelope
#    (the Stop hook). This check asserts --single is present in each such
#    caller. (build does its own one-shot analyzer pass and states --single
#    semantics in Step 4.)
# ---------------------------------------------------------------------------
echo "[7] internal evaluate callers pin --single (ADR-0006)"
before=$FAILS
SINGLE_PINNERS=(
  skills/harness-improve/SKILL.md
  skills/harness-build/SKILL.md
  hooks/stop-evaluate.sh
)
for f in "${SINGLE_PINNERS[@]}"; do
  if [ -f "$f" ]; then
    grep -qF -- '--single' "$f" || note_fail "$f invokes evaluation internally but does not pin --single (ADR-0006)"
  else
    note_fail "expected internal evaluate caller missing: $f"
  fi
done
[ "$FAILS" -eq "$before" ] && note_ok "improve / build / Stop-hook all pin --single"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "harness invariants: ALL CHECKS PASS"
  exit 0
else
  echo "harness invariants: $FAILS VIOLATION(S) FOUND (see FAIL lines above)"
  exit 1
fi
