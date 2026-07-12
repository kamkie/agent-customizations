# Claude Prompt Blocks

Use XML tags selectively for custom Claude Code CLI prompts. Anthropic documents XML sections as useful for complex prompts that mix instructions, context, examples, and input. The tag names are not special commands; choose short descriptive names that match the content.

Do not include every block by default. A plain sentence is enough for simple prompts, and `/review <pr>` is enough for a standard Claude Code review.

## Basic Custom Task

```xml
<instructions>
State the concrete job, scope, and expected end state.
</instructions>

<context>
List only facts Claude needs before using tools: paths, PR numbers, failing commands, branch/base refs, or relevant constraints.
</context>

<output_format>
Define the result shape, ordering, and brevity. Put the most actionable findings or decisions first.
</output_format>
```

## Review

```xml
<instructions>
Review the requested PR, branch, diff, or files for material correctness and regression risk.
</instructions>

<context>
Name the target, base ref, affected component, and any known risk areas.
</context>

<constraints>
Ground claims in files, diffs, or command output. Do not present inference as fact. Keep the review read-only unless the caller explicitly asks for fixes.
</constraints>

<output_format>
Return findings first, ordered by severity. For each finding, include evidence, impact, and exact file/line references. If there are no findings, say so and note residual risk briefly.
</output_format>
```

## Implementation Or Debugging

```xml
<instructions>
Implement or diagnose the requested issue fully before stopping.
</instructions>

<constraints>
Keep work tightly scoped to the requested files, component, or behavior. Avoid unrelated refactors, renames, or cleanup.
</constraints>

<verification>
Before finalizing, check the result against the task, inspected files, and command outputs. If a check fails, revise instead of reporting the first draft.
</verification>
```

## Missing Context

```xml
<constraints>
Do not guess repository facts. Retrieve missing context with tools or state exactly what remains unknown.
</constraints>
```

## Long Runs

```xml
<progress_updates>
If progress updates are needed, keep them brief and tied to phase changes, evidence found, or blockers.
</progress_updates>
```

## Follow-Up Resume Prompt

When continuing an existing Claude session, send only the new instruction:

```xml
<instructions>
Continue the prior review. Focus only on the named unresolved concern and report whether it remains valid.
</instructions>
```
