---
name: {{agent_id}}
description: "{{skill_description}}"
generated_by: "meta-harness v2.0.0 (/meta-harness:build)"
generated_at: "{{generated_at}}"
status: stub
---

# {{agent_id}} — stub

> This file is a STUB created by `/meta-harness:build` for project
> **{{project_name}}** in response to a coverage-gap or pain-pattern
> finding from `project-fit-analyzer`.
>
> Edit this file to give the agent a real role, model, and tool surface.

## Role

{{agent_role}}

## Inputs

The user (or a dispatching skill) hands this agent:

- `<input-1>` — `<description>`
- `<input-2>` — `<description>`

## Output contract

This agent emits:

- `<output shape — JSON, prose, etc.>`

## Tool surface

Allowed tools (replace with the actual minimal set):

- `Read`
- `Glob`
- `Grep`

Denied tools / patterns:

- `<TODO>`

## Procedure

1. <Step 1>
2. <Step 2>
3. <Step 3>

## DONE when

- The output above is produced, AND
- The verification check passed.

## Failure modes

| Code | Meaning |
|------|---------|
| `<UPPERCASE_CODE>` | What went wrong. |

---

*Generated as a stub. Until filled in, this agent should not be invoked in
production runs.*
