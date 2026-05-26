---
kb_id: karpathy-context-engineering
source: "Andrej Karpathy public writing (X/Twitter threads, blog posts, talks, and 'State of GPT' / 'Software 3.0' lectures)"
source_urls:
  - https://karpathy.ai/
  - https://x.com/karpathy
  - https://karpathy.github.io/
version: "1.0.0"
last_synced: "2026-05-26"
applies_to_axes: [persona, capabilities, runtime, meta_gov]
---

# Karpathy Context Engineering

> A distillation of Andrej Karpathy's public thinking on how to build LLM-based systems
> that are reliable, debuggable, and "engineering-grade" rather than vibes-grade.
> The principles below are written in his idiom and remapped to the 4-bucket harness model
> (Persona, Capabilities, Runtime, Meta-Governance) used by meta-harness.

## Why this KB exists

Karpathy's central thesis: **LLM applications are 1% modeling and 99% context engineering**.
The model is fixed; the leverage is in what you put into its context window, how that
context is structured, how outputs flow back in, and how the whole loop is debugged.
A harness that ignores these principles produces "demo-ware" — works on the happy path,
crumbles under real load.

Harness designers, treat the items below as load-bearing assumptions, not opinions.

---

## Principle 1 — Context engineering is the actual engineering

**Statement.** The job of a harness is not "prompt the model"; it is to engineer the
full context window: system prompt, retrieved facts, tool definitions, conversation
history, memory, and output schema. Each token in context is a design decision.

**Why it matters.** Models do not have telepathy. They produce conditional
distributions over the tokens you fed them. Vague harnesses produce vague outputs.
Token-level intentionality is the difference between a research demo and a product.

**Anti-pattern.** A CLAUDE.md that reads "You are a helpful coding assistant. Be smart."
No file inventory, no project conventions, no tool catalog, no failure modes.

**Pass-pattern.** A CLAUDE.md that names the project, the stack, the directories with
links to deep docs, the commands available, the canonical "how we test", the things
the model must NOT do, and an explicit pointer to the SKILL.md files that own each
verb. Every word earns its token.

---

## Principle 2 — System prompts are cognitive scaffolding, not slogans

**Statement.** A system prompt is the cognitive operating system for a single
conversation. It defines persona, allowable moves, output contract, and self-checks.
Treat it like you would treat the stdlib of a programming language: tight, documented,
versioned.

**Why it matters.** A well-engineered system prompt collapses an entire class of
"the model went off the rails" failures into "we forgot to specify behavior X". When
your prompt is a slogan, every failure is a unique mystery.

**Anti-pattern.** "Be careful and don't hallucinate." This is a wish, not an
instruction. The model has no mechanism to bind to it.

**Pass-pattern.** "When you encounter a fact you cannot verify from the provided
context, return the literal string `UNVERIFIED:` followed by the claim, and do not
proceed. Cite the file path and line range for every assertion you make about the
codebase." This is mechanizable — the model can comply because the rule is operational.

---

## Principle 3 — Eval-driven development beats vibes-driven development

**Statement.** Before you change a prompt, agent, or tool, you need a test set with
graded outputs. Eval first, prompt second. If you do not have an eval, you do not
have an engineering process — you have a vibes ratchet.

**Why it matters.** Without evals, every prompt edit is a coin flip: maybe better,
maybe worse, definitely not measurable. Vibes-driven prompting accumulates regressions
that nobody notices until production. Evals turn prompt engineering into an actual
engineering discipline with a feedback signal.

**Anti-pattern.** Iterating a system prompt by running it in the chat UI three times,
eyeballing the answers, and merging "feels better". No fixed inputs, no scoring, no
diff between runs.

**Pass-pattern.** A fixture set of ≥10 representative tasks with expected behaviors
(or a graded rubric). Every prompt change is replayed against the fixtures, scored,
and the score delta is what merges (or rejects) the change. The eval itself is a
first-class artifact in the harness.

---

## Principle 4 — Mode-1 vs Mode-2: design for the slow, deliberate loop

**Statement.** LLMs have a "mode-1" path (fast, autoregressive, vibes) and a "mode-2"
path (deliberate, tool-using, multi-step, with feedback). Production agents must be
engineered for mode-2 — explicit planning, tool calls, verification — and only fall
back to mode-1 for low-stakes glue.

**Why it matters.** Mode-1 is where hallucinations live. Mode-2 is where the model
actually checks its work against the world (filesystem, tests, type-checker, search).
A harness that does not provide mode-2 affordances (tools, verification gates,
re-entry points) forces every problem through mode-1 — which is exactly the regime
where models are unreliable.

**Anti-pattern.** A pure chat-completion harness with no tool definitions, no file
read/write, no shell, no test runner. The model is asked to "reason about" the
codebase from memory.

**Pass-pattern.** Harness exposes tools (read, edit, run, search), a TodoWrite-style
plan surface, and verification gates ("after editing, you MUST run the tests and
paste the output"). The agent's deliberation happens through tool calls, not through
unverified internal monologue.

---

## Principle 5 — Careful tokenization of context: every block has a job

**Statement.** Context is not a soup. It is a structured document with named slots:
persona, retrieved knowledge, tool catalog, conversation history, scratch space,
output schema. Each slot has its own update rules, its own size budget, and its own
trust level.

**Why it matters.** When you treat context as a soup, three things break: (a) you
exceed token budget on the wrong stuff, (b) you mix high-trust instructions with
low-trust user input (prompt injection surface), (c) you cannot debug failures
because you cannot point to "the slot that was wrong".

**Anti-pattern.** Concatenating CLAUDE.md + README.md + the last 50 chat messages +
the file the user pasted into one giant blob and shipping it. No slot boundaries,
no truncation strategy, no priority.

**Pass-pattern.** Distinct, labelled blocks in the context: `<system>` (versioned,
high-trust), `<project_memory>` (CLAUDE.md, medium-trust, project-level), `<retrieved>`
(low-trust, must be cited), `<conversation>` (mixed-trust, summarized when long),
`<scratch>` (model-owned). Each block has a documented eviction strategy and a
documented trust boundary.

---

## Principle 6 — The harness is a debugger, not a black box

**Statement.** When the model produces a wrong answer, you need to be able to ask:
"what context did it have, what was the prompt, what tool calls did it make, what
did each tool return, and where in that chain did the wheels fall off?" A harness
that does not log this is unfixable.

**Why it matters.** "The LLM is non-deterministic" is the cheap excuse. The real
reason most LLM systems are flaky is that their authors never instrumented them.
With proper logging, the same model becomes dramatically more reliable because every
failure is now a bug report with a stack trace, not a mystery.

**Anti-pattern.** Logs that say "agent ran, agent finished" with no record of the
intermediate prompt, the tool calls, the tool outputs, or the rationale.

**Pass-pattern.** Every agent invocation persists: the full system prompt (or its
hash + version), the user message, every tool call with arguments and outputs, the
final response, and a stable trace ID. Reproduction of any failure is a one-liner.

---

## Principle 7 — Compose small, sharp agents — do not build one giant brain

**Statement.** Prefer many small agents/tools with clear input-output contracts over
one monolithic agent that "does everything". Each sub-agent has a tight persona,
a small tool surface, and a strict output schema. The orchestrator's job is routing,
not reasoning.

**Why it matters.** Giant agents have giant context windows, giant prompts, giant
failure modes, and giant blast radii. They are hard to evaluate (no clean unit of
work), hard to debug (every failure could be from any of fifteen responsibilities),
and hard to improve (changing one behavior risks breaking unrelated ones).

**Anti-pattern.** A single 4000-line system prompt that defines "the assistant" and
covers planning, coding, reviewing, testing, deploying, and writing release notes.

**Pass-pattern.** A planner agent (small, returns a plan), an editor agent (small,
edits files), a reviewer agent (small, returns a structured review). The orchestrator
dispatches by intent. Each agent has its own eval set.

---

## Principle 8 — Treat the model as a stochastic component, not a wizard

**Statement.** Build the harness assuming the model will sometimes produce malformed
output, hallucinated facts, or refusals. Add a parser, a validator, a retry policy,
and a fallback. Engineering rigor here is what separates "ships" from "demos".

**Why it matters.** Every interesting agent eventually hits a long-tail input that
breaks the happy path. If your harness assumes the model "just works", you get
production stack traces with `KeyError: 'persona'`. If your harness expects failure,
you get a degraded-mode response and a logged anomaly.

**Anti-pattern.** `json.loads(model_output)` with no try/except, no schema check, no
retry on malformed output.

**Pass-pattern.** Strict JSON schema enforcement, retry-with-feedback on parse
failure ("your output was not valid JSON, here is the error, please re-emit"),
maximum retry cap, fallback to a default value with a logged warning, and a metric
counter for "model output was invalid on attempt N".

---

## How these principles map to meta-harness's 4 buckets

| Principle | Persona | Capabilities | Runtime | Meta-Gov |
|-----------|:-------:|:------------:|:-------:|:--------:|
| P1 Context engineering   | X | X | X | . |
| P2 System prompts        | X | . | . | . |
| P3 Eval-driven dev       | . | X | . | X |
| P4 Mode-1 vs Mode-2      | . | X | X | . |
| P5 Tokenization of ctx   | X | . | X | . |
| P6 Harness is a debugger | . | . | X | X |
| P7 Small sharp agents    | X | X | . | . |
| P8 Stochastic component  | . | X | X | . |

When evaluating a harness, cite these principle IDs (P1-P8) alongside KB-3 criterion
IDs to give the score actionable provenance.
