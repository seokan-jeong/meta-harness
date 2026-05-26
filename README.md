# meta-harness

A Claude Code plugin that **scores, builds, and improves project-level Claude Code harnesses** against a curated knowledge base of "what a good harness looks like" — drawn from Karpathy's context-engineering writing (including his 2026 Software 3.0 / agentic-engineering framing), Anthropic's agentic-loops guidance, and a derived 4-bucket rubric (**Persona & Rules**, Capabilities, Runtime, Meta-Governance).

The plugin treats *your project* as the system under test. It does not modify your code — it inspects the structural and procedural scaffolding around your code (your `CLAUDE.md`, your agent definitions, your skill registry, your hooks, your governance docs) and tells you how that scaffolding measures against the rubric.

## Why project-level, not global?

Global `~/.claude/` harnesses encode *your* habits across all projects. They drift, they collide with team conventions, and they make it hard to onboard collaborators who don't share your tooling. meta-harness inverts the model: each project gets a **project-local harness** that is versioned alongside its code, customized to its stack, and verifiable against a shared rubric.

## What you get

Four slash commands, each with a thin trigger and a procedural skill backing it:

| Command | What it does | Bound to |
|---------|--------------|----------|
| `/meta-harness:build` | Bootstraps a complete 4-bucket harness into the current project from bundled templates. Cwd-guarded with diff approval before any disk write. | M3, AC-1, AC-8 |
| `/meta-harness:evaluate` | Scores the current project's harness on 4 axes via LLM-as-judge; emits strict JSON plus a short human summary. | M2, AC-2, AC-6, AC-7 |
| `/meta-harness:manage` | Read-only healthcheck: 4-bucket presence, KB drift versus the plugin manifest, internal lint. Hook-callable. | M4, AC-9 |
| `/meta-harness:improve` | Iterative 3-round loop of (evaluate → manage → propose → approve → atomic apply → re-evaluate). Stagnation auto-exit at 2 consecutive non-improvements. | M5, AC-3, HR-5 |

Plus a single LLM-as-judge evaluator agent (`agents/karpathy-evaluator.md`) that all four commands invoke directly or transitively.

## Knowledge base versioning

**TL;DR**: plugin SemVer tracks code changes; KB `set_version` tracks rubric-content changes. They are decoupled for one practical reason — to make six-month-old evaluate results reproducible. Each evaluate output embeds a `kb_manifest_hash`; that single string pins the exact rubric used at scoring time, even after the plugin upgrades.

The KB is **separate from the plugin's SemVer.** The current KB set version is `1.0.0`. The plugin version is `1.0.0`. Both are tracked in `.claude-plugin/plugin.json`:

```json
{
  "version": "1.0.0",
  "kb": { "set_version": "1.0.0", "manifest_path": "docs/kb-manifest.json" }
}
```

When the KB is refreshed (e.g., to incorporate a new Karpathy talk), the KB version bumps independently and `CHANGELOG.md` records the bump under a separate `KB` heading. This separation matters: a project that pinned an evaluation result to `kb_manifest_hash` can verify reproducibility even after the plugin upgrades.

KB sources currently bundled:
- `docs/theory/karpathy-context-engineering.md` (8 principles)
- `docs/theory/anthropic-agentic-loops.md` (8 principles)
- `docs/theory/harness-4-bucket-principles.md` (the master rubric — 4 axes × 5 criteria = 20 criteria)

## Install

Inside a Claude Code session, add this repo as a plugin marketplace, then install the `meta-harness` plugin from it:

```
/plugin marketplace add seokan-jeong/meta-harness
/plugin install meta-harness@meta-harness
```

The first command clones this repo as a marketplace catalog; the second installs the plugin defined in `.claude-plugin/plugin.json`. After installation, the four slash commands below are available in any Claude Code session.

## Quick start

Once installed, inside a Claude Code session at your project root:

```
# 1. Bootstrap a complete harness into the current project
/meta-harness:build
# → cwd guard prompt → diff preview → atomic write of 9 files

# 2. Score it
/meta-harness:evaluate
# → JSON report with 4-axis scores 0-5, total 0-20, criterion-by-criterion rationale

# 3. (Later) Healthcheck without re-scoring
/meta-harness:manage --json-only
# → bucket presence + KB drift + lint warnings

# 4. (Iterative) Improve based on the score
/meta-harness:improve
# → up to 3 rounds, each with a diff preview + your approval before apply
```

All four commands respect a **cwd guard** (HR-3): they refuse to operate against `/`, `$HOME`, `/tmp`, or `/private/tmp`. `build` and `improve` additionally show an outer confirmation prompt before any disk write.

## Opt-in hooks (default OFF)

The plugin ships two hook scripts under `hooks/` but both are registered with `enabled: false` per ADR-0003. Default-OFF rationale: hook-triggered runs of manage or evaluate write to disk and (for evaluate) cost LLM tokens; the operator should consciously opt in.

To enable:

```jsonc
// hooks/hooks.json
{
  "hooks": [
    { "name": "session-start-healthcheck", "enabled": true,  ... },  // was false
    { "name": "stop-evaluate",              "enabled": true,  ... }  // was false
  ]
}
```

The hooks themselves are idempotent and harness-detecting: they silently exit 0 if the cwd is not a meta-harness-built project (signal: `.meta-harness/` directory must exist alongside `CLAUDE.md` or `agents/karpathy-evaluator.md`), so flipping them on globally is safe.

**Where reports land**: Both hooks write to `.meta-harness/reports/<UTC>-{manage,evaluate}.json` inside the target project. The `.meta-harness/.snapshot/<UTC>/` directory is also populated by `/meta-harness:build` and `/meta-harness:improve` for rollback. Add both paths to your project's `.gitignore` to avoid committing generated artifacts:

```
.meta-harness/reports/
.meta-harness/.snapshot/
```

**Manual rollback (v1.0.0)**: There is no dedicated `/meta-harness:rollback` command in v1.0.0. To undo the last `/build` or `/improve` apply, copy the matching snapshot back over the working tree from the project root: `cp -R .meta-harness/.snapshot/<UTC>/. .` (pick the timestamped directory matching the round you want to undo; the trailing `/.` copies hidden files too). A dedicated rollback command is a v1.1 candidate.

**Atomic-write asymmetry (v1.0.0)**: The session-start healthcheck routes through `/meta-harness:manage --write-report`, which writes atomically (`.tmp.$$` → `mv`). The Stop hook uses stdout redirect because v1.0.0 evaluate does not yet expose `--write-report`; on evaluate failure mid-stream, partial JSON may land in the report file. Both hooks are default-OFF, so the blast radius is bounded. v1.1 will add `--write-report` to evaluate and symmetrize the hook.

## How to read an evaluate report

A typical output:

```json
{
  "kb_manifest_hash": "sha256:...",
  "evaluator_model_id": "claude-opus-4-7",
  "axes": {
    "persona":      { "score": 4, "rationale": "..." },
    "capabilities": { "score": 3, "rationale": "..." },
    "runtime":      { "score": 4, "rationale": "..." },
    "meta_gov":     { "score": 3, "rationale": "..." }
  },
  "total": 14
}
```

Each `rationale` must cite at least one KB criterion ID (e.g., `KB-3 PER-4` for "Persona & Rules bucket has explicit scope-and-refusal statement"). The validator (`scripts/validate-eval-output.sh`) enforces ≥80-char rationale + criterion citation regex; a vacuous "looks good" rationale is rejected at parse time.

Stable reproducibility: with the same KB manifest hash and the same project input, three consecutive evaluate runs produce per-axis scores within a range of 2 (max − min ≤ 2) and a total within ±2.

**Out-of-box baseline**: A harness scaffolded by `/meta-harness:build` typically scores ~12–14/20 immediately after creation, with PER-3 ≥ 4/5 because `templates/persona/CLAUDE.md.tpl` ships with four pre-filled behavioral rules (multica-style). This is the design floor — `/improve` is expected to raise the score from this baseline, not start from zero. A total below ~6/20 immediately after build usually indicates that the bundled templates failed to write; check `.meta-harness/build-manifest.json` for the list of written files.

## Architecture decisions

Three ADRs document the key design choices:

- **[ADR-0001 Static Curated KB](docs/adr/ADR-0001-static-kb-choice.md)** — why the KB is bundled and versioned in the plugin, not dynamically fetched.
- **[ADR-0002 Single Evaluator Agent](docs/adr/ADR-0002-single-evaluator-agent.md)** — why all four commands share one `karpathy-evaluator.md` agent rather than per-axis specialists.
- **[ADR-0003 Slash + Opt-in Hooks](docs/adr/ADR-0003-slash-plus-optin-hooks.md)** — why slash commands are the primary trigger and hooks default to OFF.

## Safety contract

- **Secret deny-list (HR-4):** `.env`, `id_rsa`, `.git/`, and anything matching the bundled regex never enters the evaluator's input. **Threat model**: a secret hardcoded inside a harness file (e.g., an API key pasted into `CLAUDE.md`) could otherwise be verbatim-echoed by the LLM into a rationale string and persisted to `.meta-harness/reports/<UTC>-evaluate.json`. HR-4 is local defense-in-depth against that specific path; it is not an API-transport guard (the Claude Code host handles transport, and meta-harness adds no new network surface). AC-7 binds this — a dummy `API_KEY=test123` in a fixture must not appear in any output.
- **Cwd guard (HR-3):** Refuses `/`, `$HOME`, `/tmp`, `/private/tmp`. Symlinks resolved with `pwd -P`.
- **Atomic write (HR-1):** All disk writes use `.tmp.$$` → `mv`. Build and improve snapshot pre-overwrite files under `.meta-harness/.snapshot/<UTC>/` for rollback.
- **Cap + stagnation (AC-3 / HR-5):** Improve never runs more than 3 rounds against your project; two consecutive non-improvements auto-exit.

## What this plugin is NOT

- Not a code-quality linter. It scores your *harness*, not your codebase.
- Not a runtime agent. The evaluator runs only when you invoke it via slash command (or opt-in hook).
- Not a Karpathy/Anthropic endorsement. The KB synthesizes their public writing; they have not reviewed or approved this plugin.
- Not a one-shot. The score is meant to be re-checked over time; the KB version separation makes long-term comparisons honest.

## Reporting issues

Issues and contributions are welcome. KB versioning means: if you want to add a new principle, you bump the KB version and update `docs/kb-manifest.json`; the plugin's SemVer is independent.

## License

MIT. See [LICENSE](LICENSE).
