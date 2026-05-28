# Changelog

All notable changes to the **meta-harness** plugin are recorded in this file.

Format follows [keepachangelog.com](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer 2.0.0](https://semver.org/).

---

## [2.1.2] — 2026-05-28

**Maintenance / building-harness separation.** No behavior change for
plugin consumers. The four slash commands, the four skills, the analyzer
agent, both hook samples, and `plugin.json`'s file enumeration are
byte-identical to v2.1.1. This release exists to (a) formalize the
separation between the meta-harness plugin product and the maintainer's
own `.claude/` building-harness, and (b) advance the marketplace-tracked
tag so consumers running `/plugin install meta-harness@meta-harness` see
the current head.

### Changed

- `.gitignore` now excludes `.claude/`. The repo's `.claude/` directory
  holds the maintainer's project-local Claude Code tooling for *building*
  meta-harness (release skill, scratch agents, dogfooding state). It is
  NOT part of the plugin product, which lives at the top level
  (`skills/`, `agents/`, `commands/`, `hooks/`) and is wired through
  `.claude-plugin/plugin.json`. The new rule keeps that tooling out of
  the released tag.

### Unchanged

- All four slash commands and their skill bodies (`harness-build`,
  `harness-evaluate`, `harness-manage`, `harness-improve`).
- The 4-phase improve pipeline (tighten → lateral → sharpen →
  deterministic) introduced in v2.1.0.
- `agents/project-fit-analyzer.md`.
- Both hook samples (`hooks/session-start-healthcheck.sh`,
  `hooks/stop-evaluate.sh`).
- The plugin install surface — same skills, same agent, same hook
  documentation file.

---

## [2.1.1] — 2026-05-28

**Installable-plugin fix release.** v2.1.0 (and retroactively v2.0.0)
shipped a `plugin.json` whose `skills` array pointed at `SKILL.md`
files directly, and a `hooks/hooks.json` that used an array shape
rather than the record (event-keyed object) shape Claude Code's plugin
loader requires. Both made the plugin unloadable: skills failed with
*"path is a file; skills entries must be directories"*, hooks failed
with *"expected record, received array"*. v2.1.1 corrects both with no
behavior change to the four commands.

### Fixed

- `.claude-plugin/plugin.json` `skills` entries now point at the skill
  **directories** (`./skills/harness-build`, etc.) rather than the
  individual `SKILL.md` files. The Claude Code runtime auto-discovers
  `SKILL.md` inside each directory.
- `.claude-plugin/plugin.json` no longer references `hooks/hooks.json`
  via the `hooks` field. The ADR-0003 default-OFF promise is preserved
  by NOT registering hooks at the plugin level. Users who want the
  hooks now copy the sample into their own `settings.json` — see
  README "Opt-in hooks".
- `hooks/hooks.json` rewritten as a copyable sample in the **real**
  Claude Code hooks schema (record keyed by event name → array of
  `{matcher?, hooks: [{type: "command", command}]}` objects). The
  file is documentation only; it is not auto-loaded by the plugin.
- README "Opt-in hooks (default OFF)" section rewritten to reflect
  the actual opt-in mechanism (copy sample → user's settings.json),
  including a working real-schema example using `${CLAUDE_PLUGIN_ROOT}`.

### Unchanged

- Skill / agent / command bodies. The four slash commands behave
  identically to v2.1.0.
- Hook scripts (`hooks/session-start-healthcheck.sh`,
  `hooks/stop-evaluate.sh`) — same hard `.meta-harness/`-presence
  check, same silent-no-op on non-harnessed cwd.
- The 4-phase improve pipeline introduced in v2.1.0 is untouched.

---

## [2.1.0] — 2026-05-28

**Improve becomes a phase pipeline, not a single deterministic loop.**
v2.0's `improve` was rule-based and addressed coverage gaps by creating
empty stubs. Researching how Karpathy, Anthropic, and practitioners
like Hamel Husain frame context engineering surfaced a strong
convergence: the failure mode isn't "harnesses are too thin" — it's
"harnesses bloat in the wrong direction and Claude starts ignoring
them" (Anthropic), or "context fills past the U-curve peak and
performance degrades" (Karpathy). v2.1 reframes `improve` as a
**phase pipeline** that subtracts and reshapes before it adds.

### Added

- **4-phase pipeline in `/meta-harness:improve`**. Default order:
  `tighten → lateral → sharpen → deterministic`. Each phase has its
  own approval gate + snapshot + regression guard:
  - **Phase 1 — tighten** (LLM, deletion-only). Applies Anthropic's
    literal *"Would removing this cause Claude to make mistakes?"*
    conciseness test to every harness body file. The LLM proposes
    line-deletions; a deletion-only invariant enforces that no line is
    added or rewritten. Auto-reverts from snapshot if the post-phase
    `actionable` finding count rises.
  - **Phase 2 — lateral** (LLM, structural). Applies Anthropic's
    progressive-disclosure pattern (L1 metadata / L2 SKILL.md body /
    L3 bundled references): SKILL.md files > 300 lines or with single
    sections > 100 lines get heavy content moved to
    `references/<topic>.md`; the body retains a one-line pointer.
    Mirrors the official `pdf` skill's `FORMS.md` pattern.
  - **Phase 3 — sharpen** (LLM, YAML-description-only). Rewrites the
    YAML `description` / `when_to_use` fields of skills and agents to
    improve trigger accuracy. The body is **never** touched
    (body-untouched invariant). Target 200-300 chars per description.
  - **Phase 4 — deterministic**. The v2.0 catalog-driven loop:
    coverage-gap → stub, stale-reference → line delete,
    over-coverage → file delete. Unchanged from v2.0.
- **`--phases <csv>` flag**. Selects a comma-separated subset of
  `{tighten, lateral, sharpen, deterministic}`. Order normalized to
  canonical. `--phases deterministic` preserves v2.0 behavior byte-for-
  byte (AC-3 reproducibility).
- **State schema v2**. `.improve-state.json` schema_version bumped from
  1 → 2. Each round gains a `phase` field. `meta` gains
  `phases_requested` + `phases_executed`. v2.0 state files (schema
  v1) read-compatible: missing `phase` defaults to `"deterministic"`.
- **`pipeline_complete` exit_reason** — emitted when all requested
  phases completed normally without early termination.
- **`regressed: true` on round records** — set when a phase's
  post-fit `actionable` count rose above before-fit; the phase
  auto-reverted from snapshot. Non-fatal; pipeline advances to next
  phase.
- **ADR-0004** — Phase pipeline ordering rationale. Documents why
  `tighten → lateral → sharpen → deterministic` is the canonical
  order, citing Karpathy's U-curve, Anthropic's conciseness test, and
  Hamel's "no auto-rewrite without evals" warning.

### Changed

- **AC-3 contract scoped to phase 4.** The 3-round cap and the
  `"max 3 rounds reached"` literal are still binding, but only when
  `--phases deterministic` is set. Callers depending on AC-3
  reproducibility (CI gates, golden-file tests) MUST pin the flag.
- **Snapshot path corrected in `harness-improve` skill.** Step 6 of
  the deterministic loop used the legacy `.snapshot/` path; v2.0
  CHANGELOG declared the canonical path is `snapshots/` but the
  SKILL.md was not updated. Fixed.

### Safety

- All HR-1/3/4/5 guards preserved. Phase 1's deletion-only invariant
  and Phase 3's body-untouched invariant are new structural guards
  that make over-deletion / silent body rewrite impossible by
  construction.
- The per-phase regression guard (auto-revert on `actionable` rise)
  is Hamel's eval-gate principle applied to the LLM phases:
  the LLM proposes; the analyzer judges; the harness reverts on
  measurable regression.
- LLM phases are NOT bit-reproducible. AC-3 reproducibility is
  preserved only via the `--phases deterministic` escape hatch.

### Out of scope for v2.1 (deferred)

- **LLM-based body rewriting** (free-form prose rewrite for
  "richness"). Hamel's *"if you delegate this task to an automated
  tool too early, you risk never fully understanding your own
  requirements or the model's failure modes"* warning applies
  directly. Deferred to an eval-gated future phase.
- **Token-budget enforcement.** No automated "this skill must be ≤ N
  tokens" gate yet.
- **Multi-finding rounds in phase 4.** Still one finding per round.

---

## [2.0.0] — 2026-05-27

**Identity change.** v1 was a *generic 4-bucket harness scorer* — every
project graded against the same rubric of "what a good harness looks like".
v2 reframes the plugin as a **project-fit companion**: the standard of a
good harness *is* the project itself, and the harness should evolve as the
project's lifecycle does (script → app → polyglot service). This is a
breaking change to outputs, agent identity, and the bundled assets.

### Breaking changes

- **Agent renamed**: `agents/karpathy-evaluator.md` → `agents/project-fit-analyzer.md`.
  The agent is read-only, project-keyed, and emits fit findings rather
  than 4-axis scores.
- **Evaluate output schema rewritten.** The 4-axis `axes{persona,
  capabilities, runtime, meta_gov}` object is gone. The new shape is
  `findings[]` with categories `coverage-gap | over-coverage |
  stale-reference | pain-pattern`, severities `high | medium | low`, and
  a `fit_assessment.qualitative` bucket in `well-aligned | good | decent |
  draft`. Old reports keyed to a `kb_manifest_hash` are no longer
  reproducible against v2.
- **Reproducibility pin changed.** `kb_manifest_hash` is retired. The new
  pair is `(project_tree_hash, harness_state_hash)` — both sha256s,
  computed deterministically from the project's tree and the harness's
  enumerated files.
- **Static KB retired.** `docs/theory/` (3 files: karpathy-context-
  engineering, anthropic-agentic-loops, harness-4-bucket-principles) is
  removed. The plugin no longer bundles a separate "rubric" data set —
  the agent's prompt carries a thin meta-guide of categories.
  `docs/kb-manifest.json` and `scripts/build-kb-manifest.sh` retired.
- **Build output shape changed.** v1 wrote a fixed 9-file set. v2 writes
  a **3-file core** (CLAUDE.md, agents/project-fit-analyzer.md,
  .meta-harness/.gitignore) plus **one stub per actionable analyzer
  finding** (skill or agent shaped). The 9-file dump no longer happens.
- **Manage output schema rewritten.** Bucket-presence reporting is gone.
  Manage now reports `inventory{}` (counts), `drift{}` (project_tree_hash
  diff against the recorded state), and `lint{}` (5 rules, warnings only).
  Manage stays LLM-free.
- **Improve proposer rewritten.** The P1–P6 rule catalogue is gone. The
  v2 proposer is finding-driven: it picks the single highest-priority
  finding per round and maps it deterministically by category
  (coverage-gap / pain-pattern → stub; stale-reference → inline edit;
  over-coverage → delete-to-snapshot).
- **HR-5 stagnation condition inverted.** v1 used `delta_total ≤ 0`
  (higher score = better). v2 uses `delta_actionable ≥ 0` (lower
  actionable-finding count = better).
- **Snapshot path renamed.** `.meta-harness/.snapshot/` → `.meta-harness/snapshots/`.
- **State file added.** `<target>/.meta-harness/state.json` is written by
  build and refreshed by every improve round. Manage reads it to compute
  the drift bit.
- **ADRs retired.** ADR-0001 (static-KB choice) and ADR-0002 (single-
  evaluator agent) are deleted; their rationale no longer applies. Only
  ADR-0003 (slash + opt-in hooks) remains.
- **Templates trimmed.** v1 shipped 11 stub files. v2 ships 4:
  `templates/persona/CLAUDE.md.tpl`,
  `templates/persona/agents/_stub.md.tpl`,
  `templates/capabilities/skills/_stub/SKILL.md.tpl`,
  `templates/meta-gov/.meta-harness/.gitignore.tpl`. Old templates
  (example-skill, example-command, settings.json.tpl, ADR templates,
  README/CHANGELOG templates) are removed.
- **Harness enumeration covers Claude-Code-canonical `.claude/` paths.**
  evaluate and manage now glob BOTH legacy top-level locations
  (`skills/**/SKILL.md`, `agents/*.md`, `commands/*.md`, `hooks/*`) AND
  Claude-Code-canonical locations (`.claude/skills/**/SKILL.md`,
  `.claude/agents/**/*.md`, `.claude/commands/**/*.md`, `.claude/hooks/**`)
  plus top-level `AGENTS.md`. Surfaced by a dogfood pass against a
  Claude-Code-native Next.js project where 7 skills under `.claude/skills/`
  were invisible to the v2 evaluator and the project was mis-graded as
  "draft". Without this fix, every Claude-Code-native project would be
  systematically under-counted on fit.
- **Build writes stubs to `.claude/skills/` and `.claude/agents/`.** The
  core analyzer copy now lands at `.claude/agents/project-fit-analyzer.md`,
  and per-finding skill/agent stubs land at `.claude/skills/<slug>/SKILL.md`
  and `.claude/agents/<slug>.md` respectively. The Claude Code runtime
  auto-loads these locations, so freshly built stubs are immediately
  invokable without a manual move. Legacy top-level paths still
  evaluate-and-manage cleanly (back-compat for older harnesses) but new
  builds go canonical.

### Added

- `agents/project-fit-analyzer.md` — read-only fit analyzer. Inputs:
  `project_sketch`, `harness_state`, `(project_tree_hash, harness_state_hash)`.
  Output: strict JSON of fit findings + qualitative bucket.
- `--no-analyzer` flag on `/meta-harness:build` for fast offline core-only
  scaffolds.
- `--no-apply` flag on `/meta-harness:improve` for full dry-runs (loop
  including diff display, no writes).
- `state.json` round-trip between build/improve/manage as the shared
  drift-detection record.
- AC-9 v2: drift fixture-set — fixtures `no_record`, `tree_hash_diff`,
  `record_corrupt` each yield `drift.drifted == true`.
- `manage` `inventory.has_agents_md` boolean — surfaces a top-level
  `AGENTS.md` (the project-agent advisory convention) as a first-class
  inventory bit rather than burying it inside `agents_count`.
- `manage` lint rule **L01 extension-fallback**: when a referenced
  `<path>.ts` is absent, also try `<path>.tsx` before reporting; same for
  `.js↔.jsx`, `.md↔.mdx`, `.yaml↔.yml`. Eliminates a class of false
  positives observed during dogfood (e.g. CLAUDE.md correctly cites
  `src/lib/mdx/components.tsx` but the regex captured `.ts` form).

### Safety

- **HR-1 atomic write** preserved.
- **HR-3 cwd guard** preserved — same refusal list (`/`, `$HOME`,
  `/tmp`, `/private/tmp`), same outer-prompt gate on build / improve.
- **HR-4 secret deny-list** preserved: `.env*`, `id_rsa*`, `*.pem`,
  `*.key`, `credentials.*`, `secrets.*` filtered at enumeration AND
  post-scanned in analyzer output (16+ char base64/hex regex).
- **HR-5 stagnation** preserved in spirit; condition inverted (see above).
- **Injection guard** preserved: project / harness content is fed to the
  analyzer as **data**, not as instructions.

### Removed (v1 baggage)

- `agents/karpathy-evaluator.md`
- `docs/theory/` (all 3 files)
- `docs/kb-manifest.json`
- `scripts/build-kb-manifest.sh`
- `scripts/validate-eval-output.sh`
- `docs/adr/ADR-0001-static-kb-choice.md`
- `docs/adr/ADR-0002-single-evaluator-agent.md`

### Migration

There is no in-place migration from a v1 harness to a v2 harness. The
recommended path:

1. Move your v1 `.meta-harness/` contents aside (e.g., to
   `.meta-harness-v1-archive/`).
2. Run `/meta-harness:build` with the v2 plugin; let it produce a new
   3-file core + per-finding stubs against your current project shape.
3. Run `/meta-harness:evaluate` to confirm fit.
4. Optionally run `/meta-harness:improve` for a 3-round adjustment.

Old v1 evaluate JSON outputs and their `kb_manifest_hash` values are
no longer reproducible. v1's bundled rubric tags (e.g., `PER-3`) are
not recognized by v2.

---

## [1.0.1] — 2026-05-27

Installable-plugin fix release. v1.0.0 was tagged and pushed but not
actually installable as a Claude Code plugin — `.claude-plugin/plugin.json`
used a custom schema that Claude Code silently ignored, and there was no
`.claude-plugin/marketplace.json` for `/plugin marketplace add` to consume.
v1.0.1 corrects both.

### Fixed

- `.claude-plugin/plugin.json` rewritten to the official schema. Custom
  fields (`kb`, `scripts`, `milestones`, `future_components`, `compat`)
  were dropped from the manifest.
- `.claude-plugin/marketplace.json` added. Single-plugin marketplace named
  `meta-harness`.
- README "Quick start" replaced with correct install instructions.

---

## [1.0.0] — 2026-05-26

Initial release as a generic 4-bucket harness scorer. **Superseded by v2.0.0**
— see Breaking changes above. The v1.0.0 entry below is preserved for
historical reference only.

### Added (summary)

- 4-bucket evaluator (`agents/karpathy-evaluator.md`) — 4 axes × 5
  criteria = 20 criteria, total 0–20.
- `/meta-harness:{build,evaluate,manage,improve}` slash commands.
- Static KB under `docs/theory/` — 9 + 8 + 20 = 37 principles synthesized
  from Karpathy / Anthropic public writing.
- Templates spanning the 4 buckets; whitelisted placeholders.
- Two opt-in hooks (default OFF).

### Architecture decisions

- ADR-0001 Static Curated KB — *retired in v2*.
- ADR-0002 Single Evaluator Agent — *retired in v2*.
- ADR-0003 Slash + Opt-in Hooks — *still in force*.

---

[2.1.2]: https://github.com/seokan-jeong/meta-harness/releases/tag/v2.1.2
[2.1.1]: https://github.com/seokan-jeong/meta-harness/releases/tag/v2.1.1
[2.1.0]: https://github.com/seokan-jeong/meta-harness/releases/tag/v2.1.0
[2.0.0]: https://github.com/seokan-jeong/meta-harness/releases/tag/v2.0.0
[1.0.1]: https://github.com/seokan-jeong/meta-harness/releases/tag/v1.0.1
[1.0.0]: https://github.com/seokan-jeong/meta-harness/releases/tag/v1.0.0
