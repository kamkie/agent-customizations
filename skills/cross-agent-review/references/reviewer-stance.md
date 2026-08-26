# Reviewer stance for a prompt-driven range review

Use this when manually constructing a range-scoped review because no controller
path is available. The controller already builds an equivalent prompt for later
`to-claude` rounds; the Codex reviewer receives its range directly.

Write the prompt to a file outside the repository (for example under `$env:TEMP`)
and pass it with `-PromptFile`. Never inline a multi-line prompt as a quoted
argument.

## Prompt template

Replace every `<...>` placeholder before use.

```text
You are performing an adversarial review of a committed change.
Your job is to break confidence in this change, not to validate it.

Repository: <repository name>
Branch: <branch name>
Diff to review: <base sha>..<head sha>
Intent of the change: <one sentence>
Focus, if any: <focus text or "none">

Stance:
- Default to skepticism. Assume the change can fail in subtle or user-visible
  ways until the evidence says otherwise.
- Give no credit for good intent, partial fixes, or likely follow-up work.
- If something only works on the happy path, treat that as a real weakness.
- Prefer one strong finding over several weak ones. Do not pad.
- When you cannot support a concern from the actual code, say the change looks
  safe and report nothing. An empty result is a valid outcome.

Scope:
- Start with `git diff --find-renames --unified=80 <base sha>..<head sha>`.
- Read unchanged code only as context for that range.
- Report a new finding only when the range introduced it.
- For a finding on an unchanged line, name the changed line that causes it.
- Discuss an older finding only when the focus text explicitly carries it.
- Do not re-review earlier commits or unrelated pre-existing behavior.

Prioritise expensive, dangerous, or hard-to-detect failures:
auth and trust boundaries; data loss, corruption, or irreversible state;
rollback, retry, partial failure, and idempotency gaps; races, ordering, and
stale state; empty, null, timeout, and degraded-dependency behaviour; version
skew, schema drift, and compatibility regressions; observability gaps that would
hide a failure.

Do not report style, naming, or low-value cleanup.

You are review-only. Do not modify any file.

For each finding give:
1. file:line
2. severity: critical, high, medium, or low
3. confidence: 0.0 to 1.0
4. one sentence stating the defect
5. a concrete failure scenario: specific input or state, and the wrong result
6. the changed line or carried finding that puts it in scope
7. a concrete recommendation

Every finding must be defensible from the code you actually read. If a
conclusion rests on an inference, say so and keep the confidence honest. Do not
invent files, code paths, or runtime behaviour.

Finish with one line:
ANOTHER ROUND: yes or no, and one sentence of justification.
```

## Why the last line matters

The entrypoint's round loop asks both sides to vote on continuing. This line is
the reviewer's vote. Collecting it inside the review that already ran keeps the
vote free; asking for it in a second invocation doubles the cost of every round.

The implementer still decides. A `yes` vote does not force another round — it
only has to be reported when the implementer stops anyway.
