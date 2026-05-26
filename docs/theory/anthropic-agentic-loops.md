---
kb_id: anthropic-agentic-loops
source: "Anthropic public documentation and engineering posts (claude.ai/docs, anthropic.com/research, 'Building effective agents' post, prompt engineering guide, Claude Code docs)"
source_urls:
  - https://docs.anthropic.com/
  - https://www.anthropic.com/research
  - https://docs.anthropic.com/en/docs/claude-code
  - https://www.anthropic.com/news
version: "1.0.0"
last_synced: "2026-05-26"
applies_to_axes: [persona, capabilities, runtime, meta_gov]
---

# Anthropic Agentic Loops

> Anthropic's published guidance for building reliable agents with Claude, distilled
> into operational principles for harness designers. Source material includes
> "Building effective agents", the prompt engineering guide, the Claude Code
> documentation, and tool-use cookbooks.

## Why this KB exists

Anthropic frames agents as **LLMs that take actions in a loop, conditioned on tool
outputs**. Reliability comes from a small number of well-chosen architectural moves:
clear tool contracts, structured error handling, careful subagent decomposition,
prompt caching where it actually pays back, and project memory (CLAUDE.md) that
treats the agent as a long-lived collaborator rather than a single-turn chatbot.

A harness that ignores these moves can technically run, but it leaks tokens, gets
stuck in loops, and surprises its user.

---

## Principle 1 — The agentic loop pattern is the foundation

**Statement.** An agent is a loop: (a) the model emits text and/or tool calls,
(b) the harness executes the tool calls, (c) the tool results are appended to
context, (d) the model is invoked again. The loop terminates when the model emits
a final answer (no tool calls) or the harness hits a stop condition (max iterations,
time budget, explicit "stop" signal).

**Why it matters.** Every architectural decision in a harness is downstream of this
loop. If you don't model the loop explicitly, you can't reason about termination,
budget, error recovery, or interruption. The loop is the agent.

**Anti-pattern.** A harness with no explicit loop bound. The model is called, it
returns a tool call, the tool runs, the result is fed back, and... no maximum
iteration counter, no time budget, no stagnation detector. One bad prompt and the
agent runs forever.

**Pass-pattern.** Explicit `max_iterations` (e.g., 25), explicit wall-clock budget,
explicit "two consecutive iterations with no progress" detector, explicit user
interruption signal. Termination is a first-class concern, not an emergent property.

---

## Principle 2 — Tool design: clear contracts, narrow scope, descriptive errors

**Statement.** Each tool is an API the model must learn from a one-shot description.
That description must specify: what the tool does, when to use it, when NOT to use
it, exact parameter names and types, expected output shape, and what errors look
like. Tools should be narrow ("read this file") not wide ("do filesystem things").

**Why it matters.** Wide tools push routing logic into the model's prompt, which
inflates the system prompt and increases the chance the model picks the wrong
sub-mode. Narrow tools push routing into the harness's tool catalog, which is
deterministic, debuggable, and cheap.

**Anti-pattern.** A single `bash` tool with no further structure, used for reading
files, editing files, running tests, fetching URLs, and committing to git. The
model must reconstruct the right command every time and the harness has no per-action
audit trail.

**Pass-pattern.** Distinct `Read`, `Edit`, `Write`, `Bash`, `Grep`, `WebFetch` tools
with separate schemas. The `Bash` tool exists but the system prompt instructs the
model to prefer `Read` for reading and `Edit` for editing. Each tool returns
structured output with explicit error fields.

---

## Principle 3 — Structured error handling: tools must tell the model how to recover

**Statement.** When a tool fails, the tool's error message is the model's only signal
about how to retry. Errors should be (a) machine-distinguishable (typed or coded),
(b) human-readable, (c) actionable ("file not found at path X; try Read with absolute
path"). A silent failure or a generic "error occurred" forces the model to guess.

**Why it matters.** Models retry based on what they see. A bad error message turns
a recoverable failure into a hallucinated workaround. A good error message turns
the model into a self-healing agent.

**Anti-pattern.** Tool returns "Error: something went wrong" with HTTP 500. The
model retries with the same arguments and fails again. Or, worse, it confabulates
an alternative path that doesn't exist.

**Pass-pattern.** Tool returns
`{"error": "FileNotFound", "message": "No file at /abs/path/foo.py. Use Glob or
LS to discover available paths.", "retriable": false}`. The model sees the explicit
error code, the suggested next action, and a retriable flag — and adjusts.

---

## Principle 4 — Subagents when the work is conceptually separable, not as default

**Statement.** Spawn a subagent when the work has a clear contract (input, output),
benefits from a fresh context window (separation of concerns), or needs a different
toolset/persona. Do NOT spawn a subagent for every small task — the round-trip cost
and context loss are real.

**Why it matters.** Subagents are powerful but expensive. They cost a new model
call, lose access to the parent's working memory, and require the parent to specify
the contract in plain text (which itself is failure-prone). Used judiciously:
massive reliability gain. Used reflexively: token waste and lost coherence.

**Anti-pattern.** Every step of a multi-step plan spawns its own subagent ("first
spawn a planner subagent, then spawn an editor subagent, then spawn a reviewer
subagent"), even when the work is small enough to do inline.

**Pass-pattern.** The parent agent handles short, sequential edits directly. It
spawns a subagent only for (a) deep parallel research over many files, (b) a
sub-task with a fundamentally different persona (e.g., a code reviewer that should
not see the user's instructions), or (c) a long-running task that should not pollute
the parent's context.

---

## Principle 5 — Prompt caching: cache the stable, vary the volatile

**Statement.** Prompt caching reduces cost and latency by reusing model state across
calls when the prompt prefix is identical. Architect the prompt so that the stable
parts (system prompt, tool definitions, KB) come first and are eligible for caching,
and the volatile parts (current user input, current scratch state) come last.

**Why it matters.** A harness that interleaves stable and volatile content into one
mixed prompt cannot cache effectively. A harness that respects cache boundaries cuts
its bill by 50%+ on multi-turn workloads and shaves seconds off every iteration.

**Anti-pattern.** Putting timestamp, session ID, or current time at the top of the
system prompt. Putting the user's current message above the system instructions.
Mixing per-call config (verbosity, mode) into the cached prefix.

**Pass-pattern.** Prompt layout:
1. `<system>` (cacheable, versioned, hash-stable)
2. `<tools>` (cacheable, declared once per session)
3. `<KB>` or `<project_memory>` (cacheable per project)
4. `<conversation_history>` (cacheable up to the prefix boundary)
5. `<current_user_message>` (volatile)
6. `<scratch>` (volatile)

Cache breakpoints are placed at boundaries 3 and 4, so up to ~95% of the prompt
hits the cache on repeated turns.

---

## Principle 6 — CLAUDE.md is project memory, not a README

**Statement.** CLAUDE.md is the file the model reads at the start of every session
in a project. It is project memory: the constitution. It tells the model what the
project is, what conventions to honor, what files to look at first, what commands
to run, and what mistakes to avoid. It is NOT a marketing README for humans.

**Why it matters.** The model has no persistent memory across sessions. CLAUDE.md
is the closest analog to long-term project memory available in the harness. A weak
CLAUDE.md means every session starts from zero — the model relearns conventions by
trial and error, and the user pays for the rediscovery in tokens and time.

**Anti-pattern.** A CLAUDE.md that is a paste of the project's README, full of
marketing copy and onboarding for human contributors. No file inventory, no
conventions, no commands, no "DO NOT touch these files".

**Pass-pattern.** A CLAUDE.md with: one-line project summary, stack, directory map
(with which dirs to read first), naming conventions, test command, lint command,
build command, "files the model must not touch", "commands the model must always run
before claiming a task is done", pointer to relevant skills/agents.

---

## Principle 7 — Plan-then-act, with the plan visible

**Statement.** For non-trivial tasks, the agent should emit a plan first (e.g., a
TodoWrite-style list of steps), then execute. The plan is part of the conversation,
so the user can interrupt or correct before any expensive or destructive work
happens. Re-plan when reality diverges from the plan.

**Why it matters.** A plan is a contract between the user and the agent. It makes
the agent's intent inspectable and reversible. Without a plan, every action is a
fait accompli — by the time the user realizes the agent misunderstood, the wrong
files are already edited.

**Anti-pattern.** User asks "fix the bug in X"; agent immediately starts editing
five files without explaining what it thinks the bug is.

**Pass-pattern.** Agent reads relevant files, emits a 3-5 step plan
("1. Reproduce by running test Y. 2. Identify root cause in Z. 3. Apply fix.
4. Re-run test. 5. Report."), waits for implicit/explicit confirmation, then executes
each step with visible progress markers.

---

## Principle 8 — Output discipline: structured JSON for machine-consumed responses

**Statement.** When the next consumer of the model's output is code (a parser, a
router, another tool), the output MUST be strictly structured (JSON with a fixed
schema). When the next consumer is a human, prose is fine. Mixing prose and JSON
in the same response is a parse failure waiting to happen.

**Why it matters.** Strict structure is the only way to chain agentic steps
reliably. Loose structure leaks failure modes (markdown fences around JSON, trailing
commas, "let me also add..." prose after the JSON object) that crash downstream
code or, worse, get silently misparsed.

**Anti-pattern.** System prompt says "return your answer as JSON" with no schema,
no examples, no enforcement. Model returns
`Sure! Here's the JSON:\n\`\`\`json\n{...}\n\`\`\`\nLet me know if you want changes.`
and the parser fails.

**Pass-pattern.** System prompt says "Return EXACTLY a JSON object matching this
schema: {...}. No prose, no markdown fences, no preamble. If you cannot fulfill
the request, return {\"error\": \"<reason>\"}." Output is consumed with strict JSON
parsing + schema validation + retry-with-feedback on failure.

---

## How these principles map to meta-harness's 4 buckets

| Principle | Persona | Capabilities | Runtime | Meta-Gov |
|-----------|:-------:|:------------:|:-------:|:--------:|
| AN1 Agentic loop          | . | . | X | . |
| AN2 Tool design           | . | X | X | . |
| AN3 Structured errors     | . | . | X | . |
| AN4 Subagents             | X | X | . | . |
| AN5 Prompt caching        | . | . | X | X |
| AN6 CLAUDE.md memory      | X | . | . | X |
| AN7 Plan-then-act         | . | X | . | . |
| AN8 Structured output     | . | X | X | . |

When evaluating a harness, cite these principle IDs (AN1-AN8) alongside KB-1 (P1-P8)
and KB-3 criterion IDs to give the score actionable provenance.
