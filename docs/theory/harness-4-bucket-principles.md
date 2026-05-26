---
kb_id: harness-4-bucket-principles
source: "Synthesis of KB-1 (Karpathy) + KB-2 (Anthropic) + meta-harness design (PLAN.md, ADR-0001, ADR-0002, REQUESTS.md)"
source_urls:
  - https://karpathy.ai/
  - https://docs.anthropic.com/
version: "1.0.0"
last_synced: "2026-05-26"
role: master-rubric
applies_to_axes: [persona, capabilities, runtime, meta_gov]
---

# Harness 4-Bucket Principles (Master Rubric)

> This is the **scoring source of truth** for meta-harness's `karpathy-evaluator` agent.
> The evaluator MUST cite criterion IDs from this file in every per-axis rationale.
> If two KB files disagree, this file (KB-3) wins for scoring purposes.

## Intro: 4 buckets, 4 axes

meta-harness frames every Claude Code project harness as a composition of four buckets,
each of which becomes one scoring axis (0-5):

| Bucket | Axis ID | What lives here | Key files (typical) |
|--------|---------|-----------------|---------------------|
| A. Persona & Rules    | `persona` | Who the agent IS and what operational rules govern it; project constitution | `CLAUDE.md`, `agents/*.md` |
| B. Capabilities       | `capabilities` | What the agent CAN DO; workflows + commands | `skills/<name>/SKILL.md`, `commands/*.md` |
| C. Runtime & Tools    | `runtime` | What the agent has ACCESS to and HOW it runs | `.claude/settings.json`, `hooks/*`, MCP servers |
| D. Meta-Governance    | `meta_gov` | How the harness evolves and is governed | `README.md`, `CHANGELOG.md`, `docs/ADR-*.md` |

Each axis has **exactly 5 criteria** (total: 20). Each criterion is scored 0-5 with
concrete anchors. The per-axis score is the **rounded average of its 5 criterion
scores** (see "Aggregation" at the end). The total is the sum of the 4 axis scores
(0-20).

### Where do "rules" live in this rubric?

**Across all four buckets, but primarily in Persona.** This rubric does NOT carve
rules into a 5th bucket because 2026 industry practice (Karpathy on Software 3.0
context slots; OpenAI Codex / Stripe harness patterns; multica's behavioral-rules
CLAUDE.md template) converges on rules being **a cross-cutting concern**, not a
standalone layer:

| Bucket | Rule-shaped content scored here |
|---|---|
| **Persona & Rules** (A) | Behavioral rules in CLAUDE.md (PER-1 anchors), operational "when X do Y" rules (PER-3), prohibitions and refusals (PER-4). **Primary home of rules.** |
| **Capabilities** (B) | Workflow rules with verification steps (CAP-1, CAP-3 plan-then-act discipline), eval fixtures that encode pass/fail rules (CAP-4) |
| **Runtime & Tools** (C) | Permission allow/deny rules (RUN-1), tool-surface narrowing rules (RUN-2), opt-in hook rules (RUN-3), secret-denylist rules (RUN-4) |
| **Meta-Governance** (D) | Meta-rules captured as ADRs (MG-3), SemVer protocol rules (MG-2), improvement-loop rules with cap + stagnation (MG-5) |

The Persona axis is named **"Persona & Rules"** (not just "Persona") because the
*primary* location for behavioral and architectural rules is `CLAUDE.md`. PER-3
("rules are mechanizable, not aspirational") and PER-4 ("scope & refusal boundaries
are explicit") are the two criteria most directly scoring rule-clarity, but a
project with rules scattered across hidden config files instead of surfaced in
`CLAUDE.md` will score lower on PER-1 ("project-specific") and PER-5 ("composable,
not monolithic"). Surface your rules; do not hide them.

---

## Axis 1: Persona & Rules (`persona`, 0-5)

What is being scored: the clarity, depth, and operational usefulness of (a) **who
the agent is** in this project and (b) **what rules govern its behavior**. A
strong persona-and-rules layer collapses ambiguity at the start of every session
AND removes whole classes of failure ("model didn't know we never touch
`infra/production/`") by stating them explicitly. The axis ID stays `persona` for
schema stability; the conceptual scope includes rules. Of the 5 criteria below,
**PER-3 and PER-4** are the two most directly scoring rule clarity; **PER-1**
scores how well rules are localized in CLAUDE.md; **PER-5** scores whether rules
are composable rather than buried in a single mega-prompt.

### PER-1 — CLAUDE.md exists and is project-specific

**Description.** Does a CLAUDE.md (or equivalent project memory file) exist at the
project root, and is its content actually specific to THIS project (not generic
"you are a helpful assistant" boilerplate)?

**Score anchors.**
- **0** — No CLAUDE.md at project root.
- **1** — CLAUDE.md exists but is empty or a single-sentence placeholder.
- **2** — CLAUDE.md exists but contents are generic LLM-assistant boilerplate that
  could apply to any project.
- **3** — CLAUDE.md names the project and its main purpose, but most content is
  still generic.
- **4** — CLAUDE.md names project, stack, key directories, and at least one
  project-specific convention. Could be mistaken for another project of the same
  type only with effort.
- **5** — CLAUDE.md is unmistakably about THIS project: stack, directory map,
  conventions, "do not touch" list, required pre-commit commands, pointers to
  relevant skills/agents. Could not be lifted into another project without rewrite.

**Anti-pattern.** A CLAUDE.md with only "You are a helpful coding assistant for
this project. Be concise and accurate."

**Pass-pattern.** A CLAUDE.md that starts with a one-line project summary, then
lists stack (e.g., "TypeScript + Vite + Vitest"), key directories with which to
read first, the canonical test command, the "files I must not touch" list, and
pointers to `skills/` workflows.

---

### PER-2 — Subagent definitions exist with explicit contracts

**Description.** Are there `agents/*.md` files defining named subagents, each with
a clear persona, input contract, output contract, and a stated scope of work?

**Score anchors.**
- **0** — No `agents/` directory or no `*.md` files in it.
- **1** — `agents/` exists with stub files (only frontmatter, no body).
- **2** — At least one agent file exists; persona is described but input/output
  contracts are absent or vague.
- **3** — At least one agent file with persona + a hint of an output contract, but
  contracts are prose, not schema.
- **4** — Multiple agent files OR one agent with explicit input contract + explicit
  output contract (e.g., JSON schema). Scope of work is bounded.
- **5** — Multiple agent files, each with (a) a tight persona, (b) explicit
  input/output contracts (schema or strict spec), (c) explicit scope and
  out-of-scope statements, (d) injection/safety guards where relevant.

**Anti-pattern.** `agents/helper.md` reading "You are a helper. Help with whatever
the user asks."

**Pass-pattern.** `agents/karpathy-evaluator.md` with frontmatter declaring the
agent, body specifying "input: target project files + KB", "output: strict JSON
matching schema X", "scope: 4-axis scoring only — does not edit files", and an
injection guard clause.

---

### PER-3 — Persona is mechanizable, not aspirational

**Description.** Are the persona's instructions phrased as operational rules the
model can actually follow (testable behaviors), or as wishes/slogans?

**Score anchors.**
- **0** — Persona is missing entirely.
- **1** — Persona is pure slogan ("be helpful", "be careful").
- **2** — Persona contains some operational hints but mostly slogans.
- **3** — Persona is roughly half operational (concrete actions) and half
  aspirational (wishes).
- **4** — Persona is mostly operational rules with at least one fall-through
  default for ambiguous cases.
- **5** — Persona is entirely operational: every rule has a verifiable trigger
  ("when X, do Y") and at least one rule has an explicit anti-pattern stated as
  "must not".

**Anti-pattern.** "Be thoughtful and don't hallucinate."

**Pass-pattern.** "When you encounter a fact you cannot verify from the provided
file contents, return the literal string `UNVERIFIED:` followed by the claim, and
do not proceed. You must not invent file paths."

---

### PER-4 — Scope and refusal boundaries are explicit

**Description.** Does the persona state what the agent will NOT do and how it
should refuse? Are out-of-scope requests routed to an explicit fallback?

**Score anchors.**
- **0** — No statement of scope or refusal anywhere in persona files.
- **1** — One vague "ask if unsure" line.
- **2** — A short list of out-of-scope topics but no refusal protocol.
- **3** — A list of out-of-scope topics plus a generic refusal sentence.
- **4** — Explicit refusal protocol (what to say, what to suggest instead) for
  the listed out-of-scope cases.
- **5** — Explicit refusal protocol with examples, plus a "when in doubt, surface
  to user with question X" escalation path, plus a stated policy for safety-critical
  refusals (e.g., secrets, destructive commands).

**Anti-pattern.** No mention of refusals anywhere. The agent is expected to attempt
every request.

**Pass-pattern.** A "Refusals" section: "If asked to modify files under
`infra/production/`, refuse with: 'This area requires manual review. Please open a
PR and tag @sre.' If asked to commit secrets, refuse and surface the matched
pattern."

---

### PER-5 — Persona is composable with subagents (no monolithic mega-prompt)

**Description.** Is the project's identity distributed across small composable
files (root CLAUDE.md + small subagents), or is everything stuffed into one giant
prompt?

**Score anchors.**
- **0** — No persona files at all.
- **1** — A single >2000-line CLAUDE.md that tries to define every behavior.
- **2** — A large CLAUDE.md with maybe one stub agent file alongside.
- **3** — Reasonable CLAUDE.md size with one or two agent files, but agents
  duplicate persona content from CLAUDE.md.
- **4** — CLAUDE.md is the constitution; agent files inherit from it and add
  agent-specific persona without major duplication.
- **5** — CLAUDE.md is concise (focused on project, stack, conventions); agents are
  small files with their own personas; no significant duplication; clear pointers
  between them ("for X, see `agents/X.md`").

**Anti-pattern.** A single 3500-line CLAUDE.md that defines the persona for the
planner, the editor, the reviewer, and the release manager in one blob.

**Pass-pattern.** A 200-300 line CLAUDE.md as project constitution + 4 small agent
files (50-150 lines each) for planner, editor, reviewer, release-manager, each
with its own persona section.

---

## Axis 2: Capabilities (`capabilities`, 0-5)

What is being scored: the breadth and quality of workflows and commands the agent
can execute. Capabilities turn the persona into something that gets work done.

### CAP-1 — At least one well-formed SKILL.md workflow exists

**Description.** Are there `skills/<name>/SKILL.md` files (or equivalent workflow
definitions) and are they structured well enough to actually guide a session?

**Score anchors.**
- **0** — No `skills/` directory.
- **1** — `skills/` exists but contains only stubs or templates.
- **2** — At least one SKILL.md exists with a name and one-liner description, but
  no procedure.
- **3** — At least one SKILL.md with a multi-step procedure but no checkpoints or
  exit conditions.
- **4** — At least one SKILL.md with a multi-step procedure, explicit input/output,
  and at least one verification step.
- **5** — Multiple SKILL.md files, each with: clear trigger, structured procedure
  (numbered steps), explicit verification, explicit exit conditions, and a stated
  "when to use this skill vs. another skill" disambiguation.

**Anti-pattern.** `skills/do-stuff/SKILL.md` reading "This skill does stuff."

**Pass-pattern.** `skills/harness-evaluate/SKILL.md` with: trigger ("when user
invokes /meta-harness:evaluate"), steps (1. cwd guard, 2. collect files via
denylist, 3. invoke evaluator, 4. validate JSON, 5. render output), explicit
"DONE when output JSON validates against schema X".

---

### CAP-2 — Slash commands defined and dispatch to skills/agents

**Description.** Are slash commands defined in `commands/*.md` and do they route
the user's invocation to the right skill or agent (not just repeat the system
prompt)?

**Score anchors.**
- **0** — No `commands/` directory.
- **1** — `commands/` exists but contains only stubs.
- **2** — At least one command exists but it is a paraphrase of the system prompt
  ("you are a helpful agent...").
- **3** — At least one command with a clear purpose statement but no explicit
  dispatch to a skill or agent.
- **4** — Multiple commands with clear purposes; at least one explicitly dispatches
  to a named skill or agent.
- **5** — Multiple commands, each (a) with a clear single-sentence purpose, (b)
  dispatching to a named skill/agent, (c) accepting documented arguments where
  relevant, (d) cross-linked with the corresponding skill.

**Anti-pattern.** `commands/build.md` reading "You are a helpful agent. Build the
thing." with no reference to a build skill.

**Pass-pattern.** `commands/build.md`: "Trigger the `harness-build` skill. Args:
optional --bucket flag to scope to one of persona|capabilities|runtime|meta_gov.
See `skills/harness-build/SKILL.md` for the procedure."

---

### CAP-3 — Plan-then-act discipline is encoded somewhere

**Description.** Does the harness require or strongly encourage the agent to emit
a plan (TodoWrite-style or similar) before acting on non-trivial tasks?

**Score anchors.**
- **0** — No mention of planning anywhere in skills, agents, or persona.
- **1** — One vague line saying "think before acting".
- **2** — A statement that the agent should plan but no concrete trigger or
  format.
- **3** — A planning step appears in at least one skill, with rough format.
- **4** — Planning is required for tasks above a stated complexity threshold (e.g.,
  "tasks touching >2 files"), with a defined format.
- **5** — Planning is required, with a defined format (e.g., numbered todo list),
  an explicit "user can interrupt before execution" gate, and an explicit re-plan
  trigger when execution diverges.

**Anti-pattern.** Agent jumps straight to editing files without any plan surface.

**Pass-pattern.** SKILL.md states: "Before any task that touches more than 1 file,
emit a numbered plan via TodoWrite. Wait for user confirmation OR proceed if the
task is small. Re-plan if any step's output diverges from expectation."

---

### CAP-4 — Eval/test fixtures exist for the harness itself

**Description.** Does the harness include any eval/test fixtures that exercise its
own skills, agents, or commands? (Vibes-driven dev vs. eval-driven dev.)

**Score anchors.**
- **0** — No fixtures, no test cases, no evals anywhere.
- **1** — A README mentions "we should test this" but no actual tests.
- **2** — One stub fixture or test file with no real content.
- **3** — A small fixture set (≤3 cases) covering one happy path.
- **4** — A fixture set ≥5 cases covering happy paths and at least one edge case;
  scoring or expected output is recorded.
- **5** — A fixture set ≥10 cases with happy paths, edge cases, adversarial cases
  (e.g., prompt injection), explicit expected outputs or graded rubric, and a
  documented procedure for running them.

**Anti-pattern.** No `tests/`, no `evals/`, no fixtures, no graded examples.

**Pass-pattern.** `evals/` with fixture projects (mini-harnesses), each with an
expected score range, and a `run-evals.sh` script that runs the evaluator across
all fixtures and reports pass/fail.

---

### CAP-5 — Capability composition: skills and agents reference each other coherently

**Description.** Do skills cite which agents they invoke, and do agents cite which
skills define their workflow? Is the capability layer a graph or an unrelated heap?

**Score anchors.**
- **0** — No skills or agents.
- **1** — Skills and agents exist but never reference each other.
- **2** — One skill references one agent by name but no reverse link.
- **3** — Several skills reference agents; some agents reference back; coverage
  partial.
- **4** — Most skills reference the agents they invoke; most agents point back to
  the skill that orchestrates them; a few gaps.
- **5** — Every skill that invokes an agent names it explicitly; every agent
  invoked by a skill references that skill in its body or frontmatter; an
  `agents/`/`skills/` inventory file or section exists that explains the graph.

**Anti-pattern.** Skill mentions "the evaluator", but no link, no name, and the
agent file makes no mention of which skill orchestrates it.

**Pass-pattern.** `skills/harness-evaluate/SKILL.md` says "Invoke
`agents/karpathy-evaluator.md` with the filtered file list."
`agents/karpathy-evaluator.md` says "I am invoked by `skills/harness-evaluate`."

---

## Axis 3: Runtime & Tools (`runtime`, 0-5)

What is being scored: the runtime environment, tool surface, permissions, hooks,
and observability that determine how the agent actually executes.

### RUN-1 — `.claude/settings.json` exists and has explicit permissions

**Description.** Does `.claude/settings.json` exist with explicit allow/deny rules
for tools (read, edit, bash, etc.), or is everything wide-open by default?

**Score anchors.**
- **0** — No `.claude/settings.json`.
- **1** — `.claude/settings.json` exists but is empty or only contains the version.
- **2** — Some settings present but `permissions` is missing or trivial
  (allow-all/deny-all).
- **3** — `permissions` is present with at least an allow-list but no deny-list,
  or vice versa.
- **4** — Explicit allow-list and explicit deny-list; sensitive commands are
  denied (e.g., `rm -rf`, force pushes); some env vars or status line configured.
- **5** — Granular allow/deny with rationale comments; sensitive commands denied;
  `defaultMode: "deny"` or equivalent fail-safe; env vars set explicitly; status
  line configured; hooks declared (even if disabled).

**Anti-pattern.** No `.claude/settings.json` and the user grants permissions ad-hoc
every session, including for destructive commands.

**Pass-pattern.** `.claude/settings.json` with `permissions.allow` listing safe
read-only commands, `permissions.deny` listing destructive ones (`rm -rf /*`, `git
push --force`), `env: {DEBUG: "false"}`, statusLine configured, and a comment
referencing the project's security policy.

---

### RUN-2 — Tool catalog is narrow and well-described

**Description.** Are the tools the agent has access to documented (somewhere in
the harness or by reference to Claude Code spec) and is the tool surface narrow
(specific tools per task) rather than wide (one `bash` for everything)?

**Score anchors.**
- **0** — No tool documentation anywhere; agent uses `bash` for everything.
- **1** — Tool list exists but no description of when to use each.
- **2** — Tool list with one-line descriptions but no preference rules ("prefer
  Read over `cat`").
- **3** — Tool list with descriptions and at least one preference rule.
- **4** — Tools categorized (read, edit, run, search, web), each with description,
  use-case, and a preference rule about when NOT to use them.
- **5** — Same as 4 + explicit anti-patterns ("do not use `cat`; use `Read`") +
  explicit error-recovery expectations per tool + a clear separation of
  read-only vs mutating tools.

**Anti-pattern.** System prompt says "you have a bash tool" and that is the entire
tool documentation.

**Pass-pattern.** CLAUDE.md or persona has a "Tools" section listing
`Read | Edit | Write | Bash | Grep | Glob | WebFetch`, each with one-line purpose,
when to prefer over the alternative, and what errors to expect.

---

### RUN-3 — Hooks (if used) are explicit, opt-in, and idempotent

**Description.** Are hooks (`PreToolUse`, `SessionStart`, `Stop`, etc.) declared
explicitly with their triggers and default enabled/disabled state? Are they
idempotent (safe to re-run)?

**Score anchors.**
- **0** — Hooks directory does not exist and no hooks are configured anywhere.
- **1** — A hooks directory exists but is empty or contains only stubs.
- **2** — Hooks exist but their triggers are implicit; default enabled with no
  way to opt out.
- **3** — Hooks declared in settings or hooks.json with triggers; default state
  unclear.
- **4** — Hooks declared with explicit triggers AND explicit `enabled: true/false`;
  default is `false` (opt-in) for any mutating hook.
- **5** — Same as 4 + each hook script is idempotent (can run twice without bad
  effect) + each hook has a comment block explaining what it does, when it runs,
  what it requires, and how to disable it + sensitive hooks (Stop with side
  effects, PreToolUse with mutation) default to OFF.

**Anti-pattern.** A `Stop` hook that auto-commits to git is enabled by default
with no documentation.

**Pass-pattern.** `hooks/hooks.json` registers `SessionStart` and `Stop` hooks,
both with `enabled: false`. Each script has a header comment listing trigger,
purpose, side effects, and "how to enable". Scripts re-check preconditions before
acting and exit 0 cleanly if already in target state.

---

### RUN-4 — Secret/denylist filtering is explicit

**Description.** Does the harness explicitly prevent reading or echoing secret
files (`.env*`, `*.key`, `id_rsa*`, `credentials.*`, `secrets.*`)? Is masking
applied to outputs?

**Score anchors.**
- **0** — No mention of secret handling anywhere.
- **1** — One line in a README saying "be careful with secrets".
- **2** — Permissions deny one or two secret patterns but no broader denylist.
- **3** — A denylist exists (in settings or in an agent) covering common patterns
  but no output masking.
- **4** — Denylist covers `.env*, id_*, *.pem, *.key, credentials.*, secrets.*` +
  agent/skill instructions state "do not echo secret contents".
- **5** — Denylist as above + output masking rule for high-entropy strings (16+
  base64-like chars) outside cited regions + explicit test fixture exercising the
  denylist + a stated audit log location for any near-miss.

**Anti-pattern.** Agent reads `.env`, the contents end up in the conversation, and
the conversation is uploaded somewhere.

**Pass-pattern.** `agents/karpathy-evaluator.md` lists the denylist explicitly,
states "outputs must not echo content from these files even if seen", and a
fixture project with a dummy `.env` is part of the eval set.

---

### RUN-5 — Observability and reproducibility hooks exist

**Description.** Does the harness record enough about its own runs (prompts used,
tool calls made, manifest hashes, model ID, timestamp) to reproduce a session or
debug a failure?

**Score anchors.**
- **0** — Nothing is logged; "the LLM said something" is the only record.
- **1** — A log file is mentioned somewhere but its format and content are
  unspecified.
- **2** — Some logging exists (e.g., final response) but not enough to reproduce.
- **3** — Logging captures prompt + final response but not intermediate tool
  calls.
- **4** — Logging captures prompt hash + tool calls + tool outputs + final
  response + timestamp; KB or manifest hash recorded.
- **5** — Same as 4 + evaluator/agent results include `evaluator_model_id`,
  `kb_manifest_hash`, `timestamp`, `trace_id` + a stated procedure for replaying
  a logged session against a fixed KB snapshot.

**Anti-pattern.** No logs, no manifest hash, no model ID. When a user asks "why
did I get a different score yesterday?", there is no way to answer.

**Pass-pattern.** Every evaluator output JSON includes `kb_manifest_hash`,
`evaluator_model_id`, `timestamp`. Logs persist the full prompt (or its hash),
tool calls, and outputs to a session log file with a stable ID.

---

## Axis 4: Meta-Governance (`meta_gov`, 0-5)

What is being scored: how the harness governs its own evolution — versioning,
documentation of decisions, change history, and the discipline that keeps quality
from drifting.

### MG-1 — README.md exists and documents the harness, not just the product

**Description.** Does a README.md exist that explains the harness itself (what it
is, how to invoke it, what its commands do) — not just the product the project
ships?

**Score anchors.**
- **0** — No README.md.
- **1** — README.md exists but only describes the product, no harness mention.
- **2** — README.md mentions Claude Code or the harness in one paragraph.
- **3** — README.md has a "Harness" or "AI Assistant Setup" section with at least
  the slash commands listed.
- **4** — README.md documents slash commands, what each does, how to enable hooks
  (if any), and which agents/skills are bundled.
- **5** — Same as 4 + KB version, evaluator model ID at time of writing, a usage
  example with expected output, and a pointer to ADR-0001 (or equivalent
  architectural decisions).

**Anti-pattern.** README.md is a generic product README with no mention that
this project has a configured AI harness.

**Pass-pattern.** README.md has a clearly-titled "Harness" section that lists the
4 slash commands, says "hooks are opt-in (default OFF)", names the KB version
bundled, and links to `docs/ADR-0001-static-kb-choice.md`.

---

### MG-2 — CHANGELOG.md uses SemVer and tracks harness changes

**Description.** Is there a CHANGELOG.md that uses SemVer-style versioning and
records changes to the harness itself (not only to the product)?

**Score anchors.**
- **0** — No CHANGELOG.md.
- **1** — CHANGELOG.md exists but is empty or "TODO".
- **2** — CHANGELOG.md exists with one or two ad-hoc entries; no version numbers.
- **3** — CHANGELOG.md follows SemVer for the product but does not record harness
  changes.
- **4** — CHANGELOG.md uses SemVer and includes at least one harness-specific
  entry (e.g., "added skills/X", "bumped KB to v1.1").
- **5** — Same as 4 + a separate section or sub-section for harness changes +
  KB version bumps tracked separately from plugin SemVer + each entry references
  the relevant ADR or commit.

**Anti-pattern.** CHANGELOG.md only lists product features and bug fixes; the
KB was silently bumped without an entry.

**Pass-pattern.** CHANGELOG.md has `## [1.2.0] - 2026-...` sections with both
"Product" and "Harness" sub-sections. The Harness sub-section records skill
additions, agent changes, and KB version bumps (with KB version printed
separately).

---

### MG-3 — ADRs exist for non-trivial design decisions

**Description.** Are there `docs/ADR-*.md` (or equivalent) documents capturing
the rationale for non-trivial harness decisions (e.g., why static KB, why single
evaluator agent)?

**Score anchors.**
- **0** — No ADRs of any kind.
- **1** — One ADR placeholder file with no content.
- **2** — One ADR with context but no Options-Considered / Decision / Consequences
  structure.
- **3** — One ADR with the full structure (context, options, decision,
  consequences) but no others.
- **4** — Multiple ADRs covering the main architectural choices; each follows the
  standard structure.
- **5** — Multiple ADRs covering all non-trivial choices; each ADR has Context,
  Options Considered (≥2 alternatives with pros/cons), Decision, Consequences
  (positive + negative), and a `status: Accepted | Superseded` field with
  `superseded_by` cross-link when applicable.

**Anti-pattern.** The reason the harness uses "single evaluator agent vs ensemble"
lives only in the author's head; six months later, nobody remembers why.

**Pass-pattern.** `docs/ADR-0001-static-kb-choice.md`, `docs/ADR-0002-single-evaluator-agent.md`,
each with full structure, status, and links.

---

### MG-4 — KB or rubric version is tracked separately and visibly

**Description.** Is the KB (rubric) version tracked separately from the plugin
version, and is the current KB version surfaced to the user (in README,
CHANGELOG, or output)?

**Score anchors.**
- **0** — No KB or no version info on it.
- **1** — KB exists but no version anywhere.
- **2** — KB files have a version in frontmatter but no manifest or aggregated
  version.
- **3** — KB has frontmatter versions and a manifest, but the version is not
  surfaced to the user.
- **4** — KB version is surfaced in README and/or in each evaluator output
  (via `kb_manifest_hash`); CHANGELOG tracks KB bumps.
- **5** — Same as 4 + each KB file has `source`, `version`, `last_synced` in
  frontmatter; `kb-manifest.json` aggregates per-file hashes + combined hash;
  every evaluator result JSON includes `kb_manifest_hash`; user-facing docs
  explain how to verify KB version.

**Anti-pattern.** A user gets a score of 3 today and 4 tomorrow with no way to
tell whether the KB changed in between.

**Pass-pattern.** README says "KB version: 1.0.0". `docs/kb-manifest.json` lists
each KB file with its sha256. Every evaluator output JSON includes
`kb_manifest_hash: "<sha256>"` and `evaluator_model_id: "claude-opus-4-7"`.

---

### MG-5 — Self-evaluation / improvement protocol exists

**Description.** Does the harness define how it gets improved over time — e.g.,
an `/improve` command, a documented improvement loop, an explicit cap on automatic
improvement rounds?

**Score anchors.**
- **0** — No improvement protocol; the harness is frozen or only updated by
  whim.
- **1** — A vague "we will improve this" sentence in the README.
- **2** — An improvement command exists but with no cap or stagnation check.
- **3** — An improvement command exists with a hard cap on iterations.
- **4** — Improvement command with cap + stagnation detector (e.g., "two
  consecutive rounds with no score delta → auto-end") + user approval gate per
  round.
- **5** — Same as 4 + atomic write + snapshot backup per round + each round's
  diff visible before write + post-improvement re-evaluation with before/after
  score comparison + improvement history recorded.

**Anti-pattern.** No improvement loop; the harness drifts; nobody is sure
whether changes are net-positive or net-negative.

**Pass-pattern.** `/meta-harness:improve` command, capped at 3 rounds, with
per-round approval gates, snapshot backup to `.meta-harness/.snapshot/<ts>/`,
and a final before/after score table printed to the user.

---

## Aggregation: how to compute the per-axis 0-5 score

Each axis has 5 criteria scored 0-5. The recommended aggregation is:

> **axis_score = round_half_to_even(average(criterion_scores))**

**Canonical rounding rule (NORMATIVE for v1): banker's rounding** (round half to
nearest even integer). Chosen for reproducibility — half-up rounding biases all
.5 cases upward, which combined with LLM token-level non-determinism inflates
the AC-6 reproducibility envelope. Banker's rounding produces zero net bias
across many runs and is what `round()` does in Python 3 and IEEE 754.

The total is then `persona + capabilities + runtime + meta_gov` and ranges
from 0 to 20.

> Footnote (non-normative): older drafts of this section recommended half-up
> rounding (`0.5 -> 1`). That guidance is superseded by banker's rounding above.
> If a project's evaluator strictly requires half-up, it must say so explicitly
> in its system prompt and accept the slightly wider AC-6 envelope.

**Why simple average?** With 5 criteria per axis and a 0-5 scale, the average is
intuitive, robust to one outlier criterion, and well-aligned with the rubric's
intent (no single criterion dominates an axis). Weighted variants are deferred
to v2 (OQ-1).

**Tie-breaking and edge cases.**
- If a criterion does not apply to the project type (rare in v1), the evaluator
  may explicitly mark it `N/A` in the rationale and average over the remaining
  criteria. This must be called out in the per-axis rationale.
- The total is the integer sum of the four rounded axis scores; it is NOT
  recomputed from the 20 criterion scores. This keeps the per-axis scores and the
  total consistent under user-visible reporting.

**Worked example.**
- Axis 1 (Persona) criteria: PER-1=4, PER-2=3, PER-3=4, PER-4=2, PER-5=3 -> avg=3.2 -> rounded **3**
- Axis 2 (Capabilities) criteria: CAP-1=4, CAP-2=4, CAP-3=3, CAP-4=2, CAP-5=3 -> avg=3.2 -> rounded **3**
- Axis 3 (Runtime) criteria: RUN-1=4, RUN-2=3, RUN-3=3, RUN-4=4, RUN-5=3 -> avg=3.4 -> rounded **3**
- Axis 4 (Meta-Gov) criteria: MG-1=3, MG-2=2, MG-3=4, MG-4=4, MG-5=2 -> avg=3.0 -> rounded **3**
- Total = 3 + 3 + 3 + 3 = **12 / 20**

This file is the source of truth. When in doubt, the evaluator cites criterion IDs
from here (PER-N, CAP-N, RUN-N, MG-N) and shows the per-criterion scoring trace
in its rationale.
