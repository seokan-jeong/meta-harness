# Changelog

All notable changes to the **{{project_name}}** Claude Code harness will be
documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this harness adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file tracks **harness** changes — the contents of `CLAUDE.md`, `agents/`,
`skills/`, `commands/`, `.claude/`, `hooks/`, and `docs/ADR-*.md`. Product
changes belong in your product's own CHANGELOG (which may be the same file —
that is a project choice; if so, prefix harness entries with `[harness]`).
This separation satisfies the MG-2 criterion in the 4-bucket rubric.

## [0.1.0] — {{generated_at}}

### Added

- Bootstrapped harness via `meta-harness` v0.1.0 (`/meta-harness:build`).
- KB set `{{kb_set_version}}` pinned at manifest hash `{{kb_manifest_hash}}`.
- 4-bucket layout: Persona (`CLAUDE.md`, `agents/`), Capabilities (`skills/`,
  `commands/`), Runtime (`.claude/`, `hooks/`), Meta-Governance (`README.md`,
  this file, `docs/ADR-0001-static-kb-choice.md`).

### Notes

- Hooks ship disabled by default per `docs/ADR-0001-static-kb-choice.md`
  cross-references and the upstream `meta-harness` ADR-0003. Re-enable
  individual hooks in `hooks/hooks.json` after reading each script.
- Re-run `/meta-harness:evaluate` at the project root to get a baseline
  4-bucket score on this harness.
