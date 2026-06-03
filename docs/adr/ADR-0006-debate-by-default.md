---
adr_id: ADR-0006
title: Debate by default (strict-superset panel); internal callers pin --single
status: Accepted
date: "2026-06-03"
related_requirements: [FR-4, NFR-1, NFR-2, HR-2, AC-3, AC-6]
related_adrs: [ADR-0003, ADR-0004, ADR-0005]
supersedes_partial: [ADR-0005 §Decision (default OFF / opt-in / Workflow-tool dispatch)]
---

# ADR-0006: Debate by default; internal callers pin `--single`

## Context

ADR-0005 shipped `/meta-harness:evaluate --debate` as an **opt-in, default-OFF**
multi-agent panel, justified by an n=1 A/B and gated behind the Workflow
tool's per-run opt-in. Two things changed that calculus:

1. **The owner prioritizes quality over cost** and is willing to make debate
   the default *if its efficacy is proven* — so the cost/latency objection
   that motivated default-OFF carries little weight.
2. **A 6-project efficacy eval** (below) showed debate is consistently the
   stronger analyzer — but also exposed a real failure mode in the ADR-0005
   topology: the 2-proposer union was **not a strict superset** of a single
   pass and could *drop* a real finding (in one project, a hardcoded
   production DB credential the single pass had caught).

This ADR reverses the default and fixes the topology.

## The empirical eval (n=6)

Single-pass vs the debate panel on 6 real projects spanning stacks
(Flutter/GetX, Next.js, Python MCP, TS MCP, large-code/thin-harness,
Obsidian/21-skills). Identical inputs per arm; **every finding-delta was
ground-truth-verified against the actual repo** (real-gap / noise /
false-positive) by an adversarial verifier, spot-checked by hand.

- **First pass (ADR-0005 topology):** 4 wins / 2 ties / 0 losses;
  calibration debate-better 6/6; debate found 2–7 repo-confirmed gaps the
  single pass missed in *every* project. The 2 ties were caused by debate
  **dropping** a real single-pass finding (not a strict superset) and one
  ungroundable false positive.
- **After the superset fix (below), re-running the 2 ties:** both flipped to
  **debate wins → 6/6, 0 losses**, meeting the pre-registered bar (≥5/6 + 0
  losses). `single_only_real_lost == 0` in both; +6 and +7 real gaps added
  with no net false-positive increase.

**Honest caveats (recorded so this isn't over-read):** "no loss" is partly
*by construction* (the fix feeds the single pass into the synthesis), so the
load-bearing measured result is the **recall add without FP cost**, which is
robust across all 6. The re-run used fresh single-pass controls (the
originals were lost to a `/tmp` cleanup). The single pass's own recall is
variable — the credential finding appeared in one run and not another — so
debate raises the floor (never below single *per run*) and the *average*
recall, but does not guarantee catching rare findings a single pass also
misses. n=6, one project per stack, LLM-stochastic.

## Decision

### 1. Debate is the default; `--single` is the opt-out

`/meta-harness:evaluate` runs the **debate panel by default**. `--single`
runs one analyzer pass (the ADR-0005 default behavior). `--json-only`
(scripted / CI / hook callers) **implies `--single`** unless `--debate` is
passed explicitly. `--single --debate` together is `EVAL_BAD_ARGS`.

### 2. Strict-superset topology (the fix)

The panel is **single holistic base ∪ verified expansion**:

1. **Base** — one holistic analyzer pass (exactly the `--single` path).
2. **Expansion** — 2 diverse-lens proposers (coverage-gap/pain-pattern lens;
   over-coverage/stale-reference lens).
3. **Critic** — free-form, flags hallucinations, duplicates, severity gaps.
4. **Synthesis** — output MUST contain every **grounded base finding**
   (merge/severity-reconcile only — never silently drop one), THEN adds every
   evidence-grounded expansion finding, dropping only hallucinations and
   duplicates. → one object → the unchanged Step 5 validator.

This guarantees debate ⊇ the single pass on real findings, so **enabling the
default can never regress** vs `--single`. A new grounding rule bans
ungroundable git-state claims ("committed", "tracked", "lacks .gitignore" —
unverifiable from a file-tree sketch), which removed debate's lone false
positive in the eval.

### 3. Dispatch via Task sub-agents, not "the Workflow tool"

The panel is dispatched with the same Task sub-agent mechanism the single
analyzer already uses (Step 4) — just more passes. It is **not** "the Workflow
tool" with its per-run opt-in gate. Running `/meta-harness:evaluate` is itself
the user's invocation of the command's documented behavior, so default-ON does
not violate any opt-in contract (the concern ADR-0005 over-weighted). If
sub-agent dispatch is unavailable, the skill falls back to a single pass and
emits `EVAL_DEBATE_UNAVAILABLE`.

### 4. Internal callers pin `--single` (load-bearing for AC-3)

Because `improve`, `build`, and the Stop hook invoke evaluation internally,
they MUST pin `--single`:

- **`harness-improve`** pins `--single` on every internal evaluate call
  (phase-4 before/after fit; phase 1–3 regression guards). This keeps **AC-3**
  (phase-4 byte-reproducibility) intact and keeps the HR-5 stagnation /
  regression-revert math on the AC-6 ±1 band (both rely on the single pass).
- **`harness-build`** discovers gaps with a single analyzer pass (a bootstrap
  doesn't need debate; cost).
- **`hooks/stop-evaluate.sh`** pins `--single` (a 5-pass panel on every Stop is
  a cost footgun; also covered by the `--json-only ⇒ --single` rule).

**Linter check 7 is inverted** accordingly: it now asserts the internal
callers pin `--single` (was: `--debate` confined to the evaluate surface).

## Consequences

- **Positive.** The better analysis is now what users get by default; debate
  is a strict superset so the default never loses a finding vs `--single`;
  recall lift (2–7 real gaps/project) is on by default; `--single` preserves
  the cheap, reproducible path for CI/hooks/scripts.
- **AC-3 / AC-6 preserved** via the `--single` pin in `improve`; AC-6 is
  verified on `--single` (the reproducible path). The AC-3 verification block
  is unchanged (it already runs `--phases deterministic`, whose evaluate calls
  are now `--single`-pinned).
- **Negative.** Default `evaluate` is ~5× the cost/latency of a single pass
  (accepted: quality-first owner; scripted callers auto-opt to `--single`).
  The default path is non-reproducible (proposer diversity) — `--single` is the
  reproducible contract. Debate inherits the single pass's recall variance on
  rare findings (caveat above).
- **Major version.** This changes default behavior → **v3.0.0**.

## Future Work

- Multi-project fixture as a *standing* regression gate (n=6 here is the seed),
  ideally with a labeled gold set so recall/severity are scored, not just
  ground-truth-classified per run.
- Tune proposer count / lens set against that fixture.
- Revisit whether `build` first-time gap discovery benefits from debate once
  the bootstrap-latency tradeoff is measured.
