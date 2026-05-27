---
skill_id: {{skill_id}}
name: "{{skill_id}} (stub)"
description: "{{skill_description}}"
generated_by: "meta-harness v2.0.0 (/meta-harness:build)"
generated_at: "{{generated_at}}"
status: stub
---

# {{skill_id}} — stub

> This file is a STUB created by `/meta-harness:build` for project
> **{{project_name}}** in response to a coverage-gap finding from the
> `project-fit-analyzer` agent.
>
> **What you should do next:** rename this directory if the slug is wrong,
> fill in Trigger / Inputs / Procedure with the actual workflow this
> project needs, then delete this note. The stub form below is the
> minimum shape a skill needs to be discoverable.

## Why this stub exists

{{skill_trigger_note}}

## Trigger

When to invoke this skill (replace placeholders with the real trigger):

- User invokes `<slash-command>` in {{project_name}}, or
- Another skill dispatches here as part of a larger workflow, or
- A named hook event fires.

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| `<input-name>` | `<where it comes from>` | Yes / No |

## Procedure

1. **Pre-flight.** Validate inputs. On missing required input, emit the
   error code on stderr and exit non-zero. Do not continue with a partial
   set.
2. **Plan.** For tasks touching more than one file, emit a numbered plan
   and wait for user confirmation unless the task is small and obvious.
3. **Execute.** The actual workflow steps go here. Each step should be
   idempotent where possible, log a one-line summary of what it did, and
   stop on first error.
4. **Verify.** Run an explicit check (e.g., a command exits 0, a file
   exists, a hash matches) confirming the outputs are correct.
5. **Render.** Print a short human summary and any structured output.

## DONE when

- All declared outputs are present, AND
- The verification step in (4) passed, AND
- The user has been shown the summary.

## Failure modes

| Code | Meaning |
|------|---------|
| `<UPPERCASE_CODE>` | What went wrong. |

## Related

- `<sibling-skill>` — when to dispatch there instead.
- `<agent>` — the agent this skill orchestrates, if any.

---

*Generated as a stub. Replace this section's TODO markers with project-
specific content. The longer this stub stays in its placeholder form,
the higher `project-fit-analyzer` will rate the residual coverage gap.*
