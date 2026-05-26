# Changelog

All notable changes to the **meta-harness** plugin are recorded in this file.

The plugin's SemVer (`plugin.version`) and the bundled KB's version (`plugin.kb.set_version`) are tracked independently. A KB bump does NOT imply a plugin bump and vice versa; this preserves long-term reproducibility for projects that pinned an evaluate result to a specific `kb_manifest_hash`. KB bumps appear under their own `### KB` heading inside each release.

Format follows [keepachangelog.com](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer 2.0.0](https://semver.org/).

---

## [0.1.0] — 2026-05-26

Initial release. Six implementation milestones (M1–M6) complete; nine acceptance criteria (AC-1 through AC-9) verified.

### Added (Plugin)

- **`/meta-harness:evaluate`** (M2) — LLM-as-judge evaluator scoring the current project's harness on 4 axes (Persona, Capabilities, Runtime, Meta-Governance). Each axis 0–5; total 0–20. Emits strict JSON via `scripts/validate-eval-output.sh` (13 checks + per-axis rationale ≥80 chars + KB criterion citation regex).
- **`/meta-harness:build`** (M3) — Bootstraps a complete 9-file harness from `templates/{persona,capabilities,runtime,meta-gov}/`. Cwd-guarded outer prompt + diff preview + atomic write with snapshot rollback under `.meta-harness/.snapshot/<UTC>/`.
- **`/meta-harness:manage`** (M4) — Read-only healthcheck: 4-bucket presence enumeration, KB drift detection (vendored evaluator frontmatter vs. plugin `docs/kb-manifest.json`), 4-rule lint (L01–L04). Emits strict JSON bound to AC-9; hook-callable (no interactive prompt).
- **`/meta-harness:improve`** (M5) — Iterative 3-round loop of (evaluate → manage → propose → approve → atomic apply → re-evaluate). Rule-based proposer catalogue P1–P6 (no LLM call). 4th-round attempt prints `"max 3 rounds reached"` and exits; two consecutive non-improvements (`delta ≤ 0`) trigger stagnation auto-exit. 3-tier consent: outer cwd prompt (mandatory) + per-round approval (`--auto`-skippable) + cap+stagnation.
- **`agents/karpathy-evaluator.md`** (M1) — Single shared LLM-as-judge agent; all four commands invoke it directly or transitively per ADR-0002.
- **`skills/harness-{evaluate,build,manage,improve}/SKILL.md`** — Procedural workflows owning the state machines, JSON schemas, and contract bindings. Slash commands are thin triggers.
- **`scripts/build-kb-manifest.sh`** — Pure-bash KB manifest builder (Python-free per AK-M2-1 fix); produces `docs/kb-manifest.json` with per-entry sha256 + combined_hash.
- **`scripts/validate-eval-output.sh`** — 13-check JSON validator for evaluate output; enforces criterion-citation regex.
- **`templates/`** — 11 stub files spanning the 4 buckets; used by `/meta-harness:build` and the P1 proposal in improve. Whitelisted placeholders only: `{{project_name}}`, `{{kb_set_version}}`, `{{kb_manifest_hash}}`, `{{generated_at}}`.
- **`hooks/`** — Two opt-in hook scripts (`session-start-healthcheck.sh`, `stop-evaluate.sh`) plus `hooks/hooks.json` registry. Both `enabled: false` per ADR-0003 default-OFF policy.
- **`docs/adr/ADR-0001-static-kb-choice.md`** — End-user mirror of the static-KB architectural decision.
- **`docs/adr/ADR-0002-single-evaluator-agent.md`** — End-user mirror of the single-evaluator-agent decision (single agent, single LLM call topology).
- **`docs/adr/ADR-0003-slash-plus-optin-hooks.md`** — End-user mirror of the slash-commands-primary + opt-in-hooks decision.

### KB

- **`docs/theory/karpathy-context-engineering.md`** v1.0.0 — **9 principles** distilled from Karpathy's public writing on context engineering. Last synced 2026-05-26 against Sequoia Ascent 2026 ("Software is Changing (Again)") and his announcement of joining Anthropic's pre-training team (2026-05-19). Intro reframes the KB around the **Software 3.0** mapping (weights = CPU, context window = RAM, LLM = interpreter) and the **agentic-engineering vs. vibe-coding** distinction; P3 adds the verifiability formula `capability_spike ≈ verifiability × training_attention × data_coverage × economic_value`; P4 adds **agent-native infrastructure** (MCP, sensors/actuators, structured logs); **new P9 — jagged intelligence** — captures Karpathy's directive to empirically profile your application's circuits rather than assume smooth capability.
- **`docs/theory/anthropic-agentic-loops.md`** v1.0.0 — 8 principles from Anthropic's agentic-loops material.
- **`docs/theory/harness-4-bucket-principles.md`** v1.0.0 — Master rubric: 4 axes × 5 criteria = 20 criteria. **Axis 1 named "Persona & Rules"** (JSON key `persona` unchanged for schema stability); a "Where do rules live?" callout in the intro documents rules as a **cross-cutting concern** scored primarily by PER-3/PER-4, with rule-shaped content also surfaced in CAP-1/3/4, RUN-1/2/3/4, and MG-3/5. Banker's rounding canonical (AK-M1-1 fix).
- **`docs/kb-manifest.json`** v1.0.0 — Real sha256 per entry + combined_hash; builder script idempotent.
- KB set version: **1.0.0** (matches plugin v0.1.0 initial release).
- **`templates/persona/CLAUDE.md.tpl`** — section A renamed "Persona & Rules"; ships a **Behavioral Rules** slot pre-filled with four operational rules (Think Before Coding / Simplicity First / Surgical Changes / Goal-Driven Execution) adapted from [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills) — a community distillation of Karpathy's agentic-engineering guidance.

### Safety

- **HR-1 atomic write** — All disk writes use `.tmp.$$` → `mv`. Build and improve additionally snapshot pre-overwrite files for rollback.
- **HR-3 cwd guard** — Refuses `/`, `$HOME`, `/tmp`, `/private/tmp`. Symlinks resolved with `pwd -P`. Build + improve add outer confirmation prompt.
- **HR-4 secret deny-list** — `.env`, `id_rsa`, `.git/`, regex-matched secrets never enter evaluator input. AC-7 verified with `API_KEY=test123` fixture.
- **HR-5 stagnation auto-exit** — Improve terminates immediately on 2 consecutive `delta ≤ 0` rounds. Honest disclosure: `delta == 0` counts as non-improvement; `delta` is undefined for user-declined rounds (streak not advanced).

### Acceptance Criteria (all verified)

| AC | Bound to | Status | Verification |
|----|----------|--------|--------------|
| AC-1 | M3 build 9 files | ✅ PASS | 9-path dry-build; settings.json + hooks.json parse via jq |
| AC-2 | M2 evaluator JSON schema | ✅ PASS | 13/13 validate-eval-output checks + 8 negative tests rejected |
| AC-3 | M5 improve cap | ✅ PASS | `"max 3 rounds reached"` stdout + `rounds.length == 3` + `meta.exit_reason == "max_rounds_reached"` paper-walked |
| AC-4 | M1 KB frontmatter | ✅ PASS | 9 frontmatter lines (source/version/last_synced) across 3 KB files |
| AC-5 | M6 hooks default OFF | ✅ PASS | 4 command files exist; `jq '.hooks[].enabled'` yields only `false` |
| AC-6 | M2 reproducibility | ✅ Procedure documented | `range max − min ≤ 2` over 3 runs; operator-run gate (F4 disposition: range form unified) |
| AC-7 | M2 secret deny-list | ✅ PASS | 13 drop / 5 keep classified; `grep -F 'test123'` on output yields 0 |
| AC-8 | M3 cwd guard + atomic | ✅ PASS | Step 0 + Step 3 gates each independently abort all Step 4 writes |
| AC-9 | M4 manage bucket presence | ✅ PASS | 5/5 paper-walk scenarios (full + 4 single-bucket-removed fixtures) |

### Architecture decisions

- [ADR-0001 Static Curated KB](docs/adr/ADR-0001-static-kb-choice.md) — KB is bundled, not dynamically fetched. Reproducibility ★, offline ★, KB ageing is the trade-off (mitigated by `last_synced` + CHANGELOG KB heading).
- [ADR-0002 Single Evaluator Agent](docs/adr/ADR-0002-single-evaluator-agent.md) — All four commands share one `karpathy-evaluator.md`. Coherent rubric application + simpler context-pinning.
- [ADR-0003 Slash + Opt-in Hooks](docs/adr/ADR-0003-slash-plus-optin-hooks.md) — Slash commands are the primary trigger; hooks ship `enabled: false`. Default-permissive hooks are a footgun for LLM-cost operations.

### Limitations / Known v2 candidates

- **Customization axes** (OQ-1) — Per-language, per-stack, per-team rubric overrides not supported in v1; the 4-bucket rubric is uniform across projects.
- **LLM-based improve proposer** — v1 proposer is rule-based (P1–P6, deterministic). v2 may add LLM proposals at the cost of AC-3 determinism.
- **Concurrent improve runs** — Not lock-protected. Do not run two `/meta-harness:improve` against the same target simultaneously.
- **`--resume` flag** — Reserved; v1 specifies `IMPROVE_BAD_ARGS` if passed. Use the interactive Archive/Continue/Quit prompt instead.
- **NFR-2 load test** — Deferred to v1.5 per F2 disposition (no fixture-project AC ships in v1).
- **Verification model** — v0.1.0 verification is rule-based and paper-walked at each milestone gate (AK reviews per `.shinchan-docs/main-001/ak/`). No automated test runner or CI ships with the plugin. Acceptance-criteria "PASS" status in the table above reflects manual paper-walk + spec-binding (e.g., 9-path dry build, jq schema checks, mechanical state-machine simulation), not runtime CI coverage. Runtime CI is deferred to v0.2.
- **No input-size cap on `/meta-harness:evaluate`** — Step 1 enumerates every file matching the configured globs (`agents/*.md`, `commands/*.md`, `skills/**/SKILL.md`, `docs/ADR-*.md`, etc.); no per-glob count cap and no per-file byte cap. Very large monorepos (e.g., 50+ agents, 100+ commands) may exceed the evaluator's context window, with no graceful truncation marker emitted into the output JSON. v0.2 candidate: per-glob count cap + `input_truncated` / `truncation_summary` provenance fields in evaluate output JSON so partial-input scores are self-describing.
- **Output-masking exclusion list is under-documented (HR-4 belt-and-suspenders)** — `skills/harness-evaluate/SKILL.md` Step 1.4 documents an output-side regex (`[A-Za-z0-9+/=]{16,}`) that masks 16+ char base64-/hex-ish substrings outside `kb_citations[*].criterion_id`. The 64-char hex portion of `kb_manifest_hash` (and likely `evaluator_model_id` and `timestamp` field digits) shares that character class; a literal reading of the prose would redact them and break AC-2 check 7 (sha256 format regex). Since AC-2 PASS was paper-walked, runtime implementations are presumed to carry additional field-aware exclusions beyond `criterion_id`; the spec needs to grow the exclusion list to match. v0.2 hardening candidate.

### Internal milestones

- M1 KB + Evaluator Core (AK 14/15)
- M2 evaluate E2E (AK 13/15)
- M3 build (AK 12/15)
- M4 manage + AC-9 (AK 15/15)
- M5 improve (AK 14/15)
- M6 Hooks + Plugin Governance (this release)

---

## Upgrade notes

This is the initial release; no upgrade path applies. Future minor bumps preserve all `kb_manifest_hash` values seen in shipped reports; major bumps may invalidate them and will say so explicitly under an `### KB compatibility` heading.

[0.1.0]: https://github.com/seokan/meta-harness/releases/tag/v0.1.0
