# Round loop, scope, escalation, and report contract

Load this when a round returns findings. The entrypoint covers running a round;
this covers deciding what happens next.

## Enforce later-round scope

Round 1 reviews the whole committed change. Every later round reviews exactly
`previous-reviewed-head..current-head`.

The reviewer may read unchanged files for context, but a new later-round finding
is in scope only when the current range introduced it. When the reported line is
unchanged, the reviewer must name the changed line that causes the defect. An
older finding is also in scope when the focus file explicitly carried it forward.

Reject a new concern about earlier commits or unrelated pre-existing behavior.
Do not fix it, carry it forward, or count it as a reason for another round. If
the reviewer substantially ignores the range, discard the entire run as invalid;
it consumes no budget. Rerun only with a reviewer path that enforces the range,
or escalate when none is available.

## Classify every in-scope finding yourself

Do not accept the reviewer's verdict. Read the changed range and its necessary
context.

| Class | Meaning | Action |
| --- | --- | --- |
| confirmed | You verified the range introduced the defect | Fix it, or escalate if out of task scope |
| plausible | Could be range-caused but is not cheaply verifiable | Fix only if small, safe, and obviously harmless |
| false positive | You can state a one-line reason the alleged defect is wrong | Never "fix" it |
| review-scope violation | The range did not cause it and it was not carried forward | Reject it; do not modify the change |

## Carry only unresolved defects

The [entrypoint](../SKILL.md#then-judge) owns the re-review decision. An
evidence-backed false-positive rejection closes the finding without requiring
reviewer agreement. Record the alleged failure, relevant code or instruction,
and why the failure does not follow. Do not carry it merely to obtain consensus.

Carry credible unresolved findings only when a required later repair review can
help resolve them. State the evidence and the remaining question. Escalate a
confirmed defect outside the authorized scope or a material decision the agent
cannot resolve. An unsupported wording concern alone is not a user blocker.

## Apply the round decision

Review the complete range from the last independently reviewed head to current
HEAD and classify its effect using the entrypoint's rule. A formatting-only
change or a stronger assertion of unchanged behavior can use targeted checks;
a production behavior change, an instruction decision change, or uncertain
material risk needs scoped re-review. Do not split a risky range into small
commits to avoid review.

A user's explicit request for another round adds one to the three-round budget.
Only the user can increase that budget. If necessary re-review remains when
the budget is exhausted, report the exact unreviewed range and ask for the
needed review authority. Do not reset the counter or claim review coverage.

The reviewer vote is advisory. Record an absent vote and explain a decision
that differs from an available vote. Disagreement alone does not require a vote,
another paid invocation, or a new approval checkpoint.

## Account for later commits

A successful reviewer run covers only its recorded range and head. For each
later range, record either the next independent review or a behavior-neutral
disposition with the inspected diff, rationale, and relevant validation result.
This disposition is not an independent review of that range. Unknown effects
or meaningful risk still block completion. The repository owns final Ready,
blocking-review, owner-approval, and merge gates.

## Report contract

Provide a concise finding table with severity, location, classification,
reasoning/action, and credited fix commit where applicable. Record the reviewed
ranges, any behavior-neutral later ranges, checks and limitations, rounds
used/budget, and the reason to stop or continue. Identify genuine unresolved
defects and required user decisions separately from rejected suggestions.
