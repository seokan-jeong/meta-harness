---
adr_id: ADR-0005
title: Opt-in multi-agent debate for the evaluate analyzer pass (--debate)
status: Superseded in part by ADR-0006
date: "2026-06-02"
related_requirements: [FR-4, NFR-1, NFR-2, HR-2, HR-4, AC-6]
related_adrs: [ADR-0003, ADR-0004]
superseded_by: [ADR-0006]
---

# ADR-0005: Opt-in multi-agent debate for the evaluate analyzer pass

> **Superseded in part by [ADR-0006](ADR-0006-debate-by-default.md) (v3.0.0).**
> The mechanism (panel topology, schema ownership, injection handling, the
> empirical n=1→n=6 evidence) carries forward, but ADR-0006 **reverses the
> default**: debate is now ON by default via a strict-superset panel, the
> Workflow-tool-dispatch framing is replaced by Task sub-agent fan-out, and
> internal callers pin `--single`. Read this ADR for the original rationale;
> read ADR-0006 for the current behavior.

## Context

meta-harness makes one genuine *judgment* call: the
`project-fit-analyzer` reading a project + its harness and emitting fit
findings (`/meta-harness:evaluate`). Today that is **one LLM pass** at
`temperature: 0`. The request that prompted this ADR: *"when meta-harness
makes decisions, use Claude Code's Workflow tool to fiercely debate so the
best decision is reached."*

The decision was itself made by a **fierce-debate workflow** (Claude Code's
Workflow tool): 4 architects proposed designs under opposing mandates
(minimal · maximal · invariant-purist · architecture-fit), 6 adversarial
critiques attacked them across 3 lenses (invariant-violation · cost ·
decision-quality), and a judge synthesized the result. This ADR records
that decision and the one place the maintainer overrode the judge.

### The decision surfaces, and which can take debate

| Surface | Today | Debate? |
|---------|-------|---------|
| `evaluate` → analyzer fit-findings | 1 LLM pass, temp 0 | **yes — the center of gravity** |
| `build` → Step 4 gap discovery | reuses the analyzer | no (see below) |
| `improve` phases 1–3 (tighten/lateral/sharpen) | 1 LLM pass each, **per file** | no (see below) |
| `improve` phase 4 (pick + compose) | deterministic, **AC-3 byte-reproducible** | **never** |
| `manage` | LLM-free, hook-callable | nothing to debate |

### The crux constraint

Claude Code's Workflow tool requires **explicit per-run user opt-in**. A
consumer running `/meta-harness:evaluate` did not type "workflow" — so a
shipped skill cannot fire a Workflow unconditionally. The opt-in must be a
flag the user passes, and the default path must stay exactly today's
single pass (also preserving the hook-callable cost envelope).

## Options Considered

### Scope — Option A: debate every LLM surface (REJECTED)

Wire `--debate` into evaluate **and** improve phases 1–3 (and build's
gap-discovery). Rejected on two independent rocks the critics drove home:

1. **Re-entrant opt-in violation (fatal).** improve invokes evaluate
   *programmatically* from inside its phase turns (`harness-improve`
   Step 2; the phase 1–3 regression guards). Firing a Workflow there fires
   it from a nested, non-interactive context the user never opted into at
   that nesting level — breaching the crux.
2. **Cost fan-out (serious).** Phases 1–3 call the LLM **per file**, not
   per phase. A ~9-file harness turns ~17 single-pass calls into ~85–100
   with a panel — and those calls feed improve's single-pass regression
   auto-revert and stagnation math, whose noise floor is AC-6's ±1 band.
   Debate there could be reverted by the very noise it exists to suppress.
   Phases 1–3 are already fenced by deletion-only / body-untouched
   invariants + auto-revert + an approval gate, so debate is low-leverage.

### Scope — Option B: debate the evaluate analyzer pass only (CHOSEN)

`--debate` is parsed **only** on `commands/evaluate.md` and consumed
**only** in `harness-evaluate` Step 4. improve and build never parse it and
never forward it; every nested / transitive / hook evaluate call runs
single-pass. This satisfies the crux *by construction* (the flag is typed
on a top-level interactive command), keeps phase 4 AC-3-reproducible
(structurally unreachable), and targets the genuine center of gravity —
because build Step 4 and improve phase 4 already consume the analyzer's
findings, a better analyzer pass helps them indirectly without itself
debating.

### Reconcile — intersection (judge) vs. union-with-verification (CHOSEN, override)

The debate judge specified a **deterministic intersection** of the two
proposer outputs to provably stay inside AC-6's ±1 band. The
decision-quality critique showed why that is upside-down for a *gap
finder*: intersection delivers **precision the Step 5 validator already
guarantees** (every `evidence.ref` must exist in the inputs or the finding
is rejected) while **discarding recall** — a real gap only one proposer
caught is dropped. "Find more of what a single pass missed" is the actual
value of debating a gap analysis.

The maintainer override: debate-mode does a **union of candidate findings
→ adversarial verification** (drop hallucinated/duplicate, reconcile
severity), biasing for recall + calibration. This is safe precisely
*because* debate is evaluate-only: AC-6's ±1 band is relied on inside
improve's control flow, and improve never runs debate-mode — so widening
the opt-in evaluate finding set never perturbs stagnation/regression math.
We therefore do **not** invent a weaker "AC-6-debate band" (the move three
critics attacked); we state plainly that the opt-in path is a *thoroughness
escalation*, not a reproducibility guarantee. AC-6 continues to characterize
the default path, verified on the default path.

## Decision

Add a single opt-in boolean flag **`--debate`** (default OFF) to
`/meta-harness:evaluate` only. When set on a top-level interactive run,
`harness-evaluate` Step 4 dispatches a Claude Code Workflow-tool panel
**instead of** the single analyzer call:

1. **Proposers (2, diverse-lens, schema-conformant).** Two
   `project-fit-analyzer` instances over the *identical* Step 4.2 inputs.
   Both run the full analysis (all four categories, full evidence rules);
   one is additionally nudged to scrutinize coverage-gap / pain-pattern
   (what's missing), the other over-coverage / stale-reference (what's
   stale). The nudge steers attention, never the schema.
2. **Critic (1, free-form, DATA-only).** Receives both candidate arrays as
   DATA and flags (a) `evidence.ref`s absent from the inputs, (b) duplicates
   across the arrays, (c) severity disagreements. It emits free-form notes
   and **never the schema** — so there is never a second schema emitter.
3. **Synthesis (1 `project-fit-analyzer` pass, temp 0).** Fed the unchanged
   four inputs **plus** an additive optional `debate_transcript` input
   (both candidate arrays + critic notes, DATA-fenced). It **unions** the
   evidence-grounded findings, drops critic-flagged hallucinations, merges
   duplicates, applies the reconciled (more-conservative) severity, re-ids,
   recomputes `fit_assessment` counters, and emits **exactly one** object
   per its unchanged `output_contract`.
4. The single synthesized object re-enters the **byte-unchanged** Step 5
   validator (schema, hash echo, enums, evidence-ref existence,
   counters) + Step 4.4 redaction + retry-once-then-`EVAL_INVALID_JSON`.

**Fail-soft.** If the Workflow tool is unavailable in the session,
`harness-evaluate` falls back to the single analyzer pass and emits a
distinct `EVAL_DEBATE_UNAVAILABLE: ran single-pass` notice on stderr — a
consumer is never silently told a single pass was "debated".

`project-fit-analyzer.md` stays the **sole schema owner**: the only schema
emitters are the existing analyzer (proposers + synthesis), under its
unchanged `output_contract` and unchanged `temperature: 0`; the panel's
diversity lives in the two proposer instances, not in raising temperature.
The agent file change is purely additive — one optional `debate_transcript`
input, a short "Synthesis mode" note, and an injection-guard extension.

## Consequences

### Positive

- The one real judgment call gains opt-in multi-agent rigor aimed at
  **recall + severity calibration**, the values a single temp-0 pass plus
  the Step 5 evidence wall cannot provide.
- Default path, build, all of improve, manage, and every hook / nested /
  transitive evaluate call are **byte-for-byte unchanged** and never fire a
  Workflow — zero added cost unless the operator types `--debate`.
- AC-3 (phase 4) is structurally unreachable; AC-6 is preserved as one
  contract on the default path and is *not* redefined.
- Schema ownership, HR-1 apply path, HR-2 injection handling, HR-3/HR-4,
  and Invariant 6 all hold (see §Invariant ledger).

### Negative

- `--debate` is a deliberately **non-reproducible** opt-in pass (proposer
  diversity is its point). It is documented as a thoroughness escalation,
  not a tolerance band, so no fixture currently bounds its variance — see
  Future Work.
- A poisoned project file could induce a proposer to relay a
  crafted instruction inside a finding's free-text field. Mitigation: the
  critic/synthesis prompts treat all `debate_transcript` content as DATA,
  and a relayed finding still cannot survive Step 5 without a real
  `evidence.ref`. The agent's injection guard is extended to name this.
- One new maintenance surface. Mitigation: **linter check 7** confines the
  literal `--debate` to `commands/evaluate.md` + `skills/harness-evaluate/SKILL.md`
  so a future hand-edit wiring it into improve/build/a hook fails CI.

### Neutral / Invariant ledger

| Invariant | How preserved |
|-----------|----------------|
| AC-3 | `--debate` never reaches improve; phase 4 pick/compose has no analyzer call; the AC-3 verification block passes verbatim. Linter check 7 enforces non-leakage. |
| AC-6 | Default path identical → identical ±1 band, verified on the default path. Debate-mode is opt-in, evaluate-only, never feeds improve's stagnation/regression math, and makes no reproducibility claim. |
| HR-1 | Debate is upstream of every write; evaluate's only write (`--raw-out`) and improve's apply path are untouched. |
| HR-2 | Proposers inherit the agent guard on the 4-input prompt; critic/synthesis prompts + the agent's injection-guard section name `debate_transcript` and candidate-finding free-text fields as DATA. |
| Invariant 6 | A shipped skill **using** the Workflow tool against the consumer target is permitted; it is distinct from **editing** the plugin's own files, which stays forbidden. |
| Workflow opt-in | The skill fires a Workflow only inside `if --debate`, and the flag is user-typed on a top-level interactive command. Fail-soft to single-pass otherwise. |
| schema ownership | Only the analyzer emits schema; the critic emits free-form notes; `output_contract` + `temperature: 0` unchanged. |

## Empirical check (n=1, 2026-06-02)

Before committing, the design was A/B-tested on a real consumer project
(`glucofit-flutter`, a GetX/GraphQL/Hive/Sendbird Flutter app whose harness
is design-review/UI-centric). Both arms were given a **byte-identical**
(`project_sketch` + `harness_state`) and the same analyzer spec; the only
variable was single-pass vs. the `--debate` panel.

| Axis | Single pass (A) | Debate panel (B) |
|------|-----------------|-------------------|
| Findings | 5 (1 high / 3 med / 1 low) | 6 (1 high / 5 med) |
| **False positives** | **1** — claimed `lib/utils/theme_data.dart` was a dead reference; the file **actually exists** (an absence it could not verify) | **0** — both proposers refused to assert the unverifiable absence; the critic confirmed it |
| Real gaps the other missed | — | **+2**, both ground-truth-verified: backend/telemetry operationalization (GraphQL/Amplitude/Sentry/Sendbird as prose-only) and the Shorebird OTA release gate |
| Severity calibration | `AGENTS.md` staleness = medium | recalibrated to **high** (a root doc loaded every session that actively misdirects), better calibrated |

On this case debate was modestly **better on all three axes** — precision
(0 vs 1 false positive), recall (+2 real gaps), and calibration. It also
**vindicated the union override** over the rejected intersection design:
each of the two new findings was surfaced by only *one* proposer, so an
intersection reconcile would have dropped both — the entire recall gain.

**Honest caveats.** (1) **n=1** — one project, one run; LLM-stochastic, not
statistically robust. (2) **~5× cost** (≈5 agents) for a modest, incremental
gain over an already-strong single Opus pass. (3) The test harness's
per-directory tree-truncation *partly manufactured* the single pass's lone
false positive (it hid `theme_data.dart`); a real evaluate (5000-entry cap)
would not truncate this project, so the precision delta is partly a test
artifact — though debate's *restraint under uncertainty* is a generalizable
virtue. Net: a real but small improvement on one real test, not proof it
generalizes.

## Future Work

- **Fixture-measured quality bar.** The §Empirical check above is n=1; the
  decision-quality critique's standing ask is to turn it into a real gate:
  measure **recall lift** on missed gaps and **severity agreement** across a
  *multi-project* labeled fixture, so the thoroughness claim rests on more
  than one case. Until then `--debate` ships as an explicitly experimental
  opt-in whose one real A/B was favorable but not conclusive.
- **Proposer count / lens set as a tuned knob.** Fixed at 2 here
  (cost-bounded). A fixture could justify more proposers or different
  lenses.
- **Reusing the panel for build's first-time gap discovery.** Deferred:
  build runs against an empty or just-composed harness where the recall
  win is least justified and the latency cost lands on a bootstrap.
