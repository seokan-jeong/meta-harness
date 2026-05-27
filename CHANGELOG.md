# Changelog

All notable changes to the **meta-harness** plugin are recorded in this file.

Format follows [keepachangelog.com](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer 2.0.0](https://semver.org/).

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

[2.0.0]: https://github.com/seokan-jeong/meta-harness/releases/tag/v2.0.0
[1.0.1]: https://github.com/seokan-jeong/meta-harness/releases/tag/v1.0.1
[1.0.0]: https://github.com/seokan-jeong/meta-harness/releases/tag/v1.0.0
