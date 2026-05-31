# CLAUDE.md — maintaining the **meta-harness** plugin

> This file orients Claude to working on **this repository** — the
> meta-harness plugin's own source. It is the *maintainer's* harness.
>
> Do **not** confuse it with `templates/persona/CLAUDE.md.tpl`, which is the
> template meta-harness *emits into other people's projects*. This file is
> about building the plugin; that template is a product artifact.

## What this repo is

meta-harness is a Claude Code **plugin**: four slash commands + one analyzer
agent + four workflow skills that *build, evaluate, monitor, and improve a
per-project harness for some other project*. The standard of a "good harness"
is that other project, not a universal rubric (see `README.md`).

This repo is therefore **self-referential**: the `agents/`, `skills/`,
`commands/`, and `hooks/` directories here are simultaneously the shipped
**product** and — when you point a Claude Code session at this repo — the
**harness** that session loads. Keep the two hats distinct when you edit.

## The one thing to know first (Invariant 6)

The four shipped skills **deliberately refuse to edit the plugin's own
files** — `skills/harness-build/SKILL.md` Invariant 6: *"never modifies the
`meta-harness` plugin's own files."* That keeps the product safe to run
against consumer projects, but it means:

- **You maintain this repo by hand-editing**, not by running
  `/meta-harness:build` or `/meta-harness:improve` against it. Those write
  consumer-style harness files and will not (and should not) touch the
  product here.
- **`/meta-harness:evaluate` and `/meta-harness:manage` are read-only and
  *are* safe to run on this repo** as a self-check. This `CLAUDE.md`, the
  `scripts/check-skill-invariants.sh` linter, and the `.github/` CI were all
  added in response to a self-`evaluate` run that flagged the missing
  maintainer harness, dangling ADR refs, and cross-skill duplication.

## Repo map — product vs. workspace

| Path | Role | Committed? |
|------|------|-----------|
| `commands/*.md` | The 4 user-facing slash commands (thin triggers). | ✅ product |
| `skills/harness-*/SKILL.md` | The 4 workflow skills (the real procedures). | ✅ product |
| `agents/project-fit-analyzer.md` | The single LLM-as-judge analyzer; owns the output schema. | ✅ product |
| `hooks/` | Two opt-in hook scripts + `hooks.json` sample (default OFF). | ✅ product |
| `docs/adr/` | Public ADR mirror (the decisions that ship). | ✅ product |
| `templates/` | Scaffolds **emitted into target projects** by `build`. | ✅ product |
| `.claude-plugin/{plugin,marketplace}.json` | Plugin + marketplace manifests. | ✅ product |
| `scripts/check-skill-invariants.sh` | Maintainer/CI consistency linter (see below). | ✅ repo tooling |
| `.github/workflows/` | CI that runs the linter. | ✅ repo tooling |
| `.claude/` | The maintainer's **building-harness** skills (`release`, `changelog-draft`, `adr-new`). The harness-that-builds-meta-harness — **not** the product. | 🚫 gitignored |
| `.shinchan-docs/` | team-shinchan workflow state: `REQUESTS.md`, `PLAN.md`, ADR **drafts** (incl. retired ADR-0001/0002), ontology, work-tracker. | 🚫 gitignored |
| `.openchrome/` | Local MCP sidecar state. | 🚫 gitignored |
| `.meta-harness/` | Plugin runtime artifacts, if you ever dogfood against this repo. | 🚫 gitignored (reports/snapshots) |
| `agents/.context.md`, `skills/.context.md`, `hooks/.context.md` | Auto-generated per-directory context, **"Do not edit"** — regenerated each session. | (transient) |

The `.gitignore` header comments are the authoritative explanation of the
gitignored set; read them before adding to it.

## How the pieces fit

- **Command → skill → agent.** Each `commands/*.md` is a *thin trigger*: it
  enforces the cwd guard (HR-3), then delegates to its skill. The procedure
  lives in the skill — **don't** duplicate procedure into the command.
- **Skills are the single source of truth.** `skills/harness-evaluate/SKILL.md`
  is canonical for the shared recipes (project sketch, tree-hash, HR-3 cwd
  guard, HR-4 denylist, atomic write); `build`/`manage` restate them so each
  skill stays self-contained at runtime. That duplication is intentional —
  **the linter keeps the copies from drifting** (see below).
- **The agent owns the output schema.** `agents/project-fit-analyzer.md`
  `output_contract` is the one definition of the evaluate JSON. Skills
  reference it; they never redefine it.
- **Workflow skills are `user-invocable: false`** (hidden from the slash
  menu); the user-facing surface is the four commands. Keep new workflow
  skills hidden unless they're meant as direct slash entries.
- **Hooks ship OFF.** `plugin.json` intentionally omits a `hooks` field
  (ADR-0003); `hooks/hooks.json` is a copy-paste sample and carries
  `_plugin_version`. Don't auto-enable hooks.

## Safety invariants — must survive every edit

These are load-bearing. Requirement IDs (`FR-*`, `NFR-*`, `HR-*`, `AC-*`,
`R-*`) trace to `.shinchan-docs/main-001/REQUESTS.md` (gitignored). The
`README.md` "Safety contract" section is the shipped summary.

| ID | Invariant |
|----|-----------|
| **HR-3** | cwd guard refuses `/`, `$HOME`, `/tmp`, `/private/tmp`; symlinks resolved via `pwd -P`. |
| **HR-4** | Secret denylist — `.env*`, `id_rsa*`, `*.pem`, `*.key`, `credentials.*`, `secrets.*` — never enters analyzer input; output is post-scanned for 16+ char base64/hex. |
| **HR-1** | All disk writes are atomic (`.tmp.$$` → `mv`); destructive applies snapshot first. |
| **HR-2** | Project/harness file content is fed to the analyzer as **data**, never instructions (injection guard). |
| **AC-3 / HR-5** | `improve` never exceeds 3 deterministic rounds; stagnation auto-exits. |

If you change one of these in any skill, change it everywhere — and run the
linter to confirm you did.

## Before you commit

```bash
bash scripts/check-skill-invariants.sh   # exit 0 = clean
```

It guards six things hand-edits tend to break:

1. **HR-4 denylist completeness** — all 6 patterns present wherever the list is enumerated.
2. **HR-3 cwd-guard blocked paths** — `$HOME` / `/tmp` / `/private/tmp` named together.
3. **ADR reference integrity** — every `related_adrs:` entry resolves to a real `docs/adr/ADR-XXXX-*.md` (prevents the retired-ADR dangling-ref class).
4. **Manifest JSON validity** — `plugin.json`, `marketplace.json`, `hooks.json` parse.
5. **Version sync** — `plugin.json` ⇆ `marketplace.json` ref ⇆ `hooks.json` `_plugin_version` ⇆ README badge agree.
6. **Required build templates present** — the `BUILD_TEMPLATE_MISSING` set under `templates/` exists (excludes `project-fit-analyzer.md.tpl`, which build deliberately does not use).

CI (`.github/workflows/harness-lint.yml`) runs the same script on push/PR.

## Releasing

Releases are driven by the **building-harness** skill at
`.claude/skills/release/SKILL.md` (gitignored — it is maintainer tooling, not
shipped). It bumps the four version-sync points above + the CHANGELOG tag
link, commits via `-F` (the commit-msg hook rejects HEREDOC `-m`), and pushes
commit and tag as **separate** `git push` calls. The
`## [X.Y.Z] — YYYY-MM-DD` CHANGELOG section must exist *before* you invoke it
(release does not write release notes) — draft it with the **`changelog-draft`**
building-harness skill (from the commit range since the last tag), then refine
the wording. **Do not bump the version for ordinary edits** — version changes
belong to a release.

Record architecture decisions under `docs/adr/` with the **`adr-new`**
building-harness skill (auto-increments the ADR number + scaffolds the
canonical skeleton); the linter's check 3 then enforces that any
`related_adrs:` pointing at it resolves.

## Conventions

- **Conventional Commits**: `type(scope): subject` (`fix`, `feat`, `chore`,
  `docs`; scopes like `skills`, `release`, `repo`, `improve`). End commit
  messages with the `Co-Authored-By:` trailer.
- **Language**: product docs (README, skills, commands, agent) are in English;
  ADR rationale and user interaction may be Korean. Match the file you're in.
- **Conciseness** (ADR-0004 ethos): for each line ask "would removing this
  cause a mistake?" If not, cut it. Skills cluster at 150–500 lines.
- **Surgical edits**: touch only what the task needs; don't reformat or
  refactor unrelated content in the same diff.
