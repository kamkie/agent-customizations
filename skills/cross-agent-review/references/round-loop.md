# Round loop, scope, escalation, and report contract

Load this when a round returns findings. The entrypoint covers running a round; this covers deciding what happens next.

## Enforce later-round scope

Round 1 reviews the whole committed change. Every later round reviews exactly `previous-reviewed-head..current-head`.

The reviewer may read unchanged files for context, but a new later-round finding is in scope only when the current range introduced it. When the reported line is unchanged, the reviewer must name the changed line that causes the defect. An older finding is also in scope when the focus file explicitly carried it forward, including a repaired finding the reviewer answers as still open.

A new concern about earlier commits or unrelated pre-existing behavior is out of scope. Do not fix it, carry it forward, or count it as a reason for another round. Report it as pre-existing only when checking its scope showed a real defect that predates the change; otherwise reject it. If the reviewer substantially ignores the range, discard the entire run as invalid; it consumes no budget. Rerun only with a reviewer path that enforces the range, or escalate when none is available.

## Classify every in-scope finding yourself

Do not accept the reviewer's verdict. Read the changed range and its necessary context.

| Class | Meaning | Action |
| --- | --- | --- |
| confirmed | You verified the range introduced the defect | Fix it with the other occurrences of its kind in the change, or escalate if out of task scope |
| plausible | Could be range-caused but is not cheaply verifiable | Fix only if small, safe, and obviously harmless |
| false positive | You can state a one-line reason the alleged defect is wrong | Never "fix" it |
| review-scope violation | The range did not cause it and it was not carried forward | Do not modify the change; report a verified defect that predates the change as pre-existing, reject anything else |

## Carry only unresolved defects

The [entrypoint](../SKILL.md#then-judge) owns the re-review decision. An evidence-backed false-positive rejection closes the finding without requiring reviewer agreement. Record the alleged failure, relevant code or instruction, and why the failure does not follow. Do not carry it merely to obtain consensus.

Carry credible unresolved findings only when a required later repair review can help resolve them. State the evidence and the remaining question. Escalate a confirmed defect outside the authorized scope or a material decision the agent cannot resolve. An unsupported wording concern alone is not a user blocker.

## Apply the round decision

Review the complete range from the last independently reviewed head to current HEAD and classify its effect using the entrypoint's rule. A formatting-only change or a stronger assertion of unchanged behavior can use targeted checks; a production behavior change, an instruction decision change, or uncertain material risk needs scoped re-review. The entrypoint's disposition for a low- or medium-finding repair from round 2 on applies to that repair alone; a range that also holds another behavior change needs the scoped re-review. Do not split a risky range into small commits to avoid review.

Three rounds is the default budget, for every kind of change, automatically extending up to six total rounds while confirmed findings strictly decrease from the previous round and no repaired defect class repeats. Each change the user makes or asks for, and each round the user explicitly requests, adds one round. Spend the remaining budget — including converging rounds up to the six-round ceiling — on necessary re-review without asking. Pause and ask the user once per block only when necessary re-review remains after the three-round base and findings are no longer converging (confirmed count did not drop or a repaired defect class repeated), or when the six-round ceiling is reached; name the exact unreviewed range, what the last round found, and whether findings are shrinking. Offer a block of up to three more rounds, or closing the repair by disposition. Rounds in a granted block run without asking again, each only while a repair still needs a scoped review under the entrypoint's rule, and the outstanding review blocks completion until it runs or the user declines it. Only for a repair whose further review the user declines, inspect it, run targeted validation, and record it as closed under the round limit, not as reviewed. A confirmed open defect remains a blocker for the repository's Ready gate. Do not reset the counter or claim review coverage.

The reviewer vote is advisory. Record an absent vote and explain a decision that differs from an available vote. Disagreement alone does not require a vote, another paid invocation, or a new approval checkpoint.

## Account for later commits

A successful reviewer run covers only its recorded range and head. For each later range, record the next independent review, a behavior-neutral disposition, a low- or medium-finding repair disposition, or a round-limit disposition for a validated repair whose further review the user declined, each disposition with the inspected diff, rationale, and relevant validation result. A disposition is not an independent review of that range. A material change that is not a repair keeps its review requirement and blocks completion while it is unmet. Outside those dispositions, unknown effects or meaningful risk still block completion. The repository owns final Ready, blocking-review, owner-approval, and merge gates.

## Report contract

Provide a concise finding table with severity, location, classification, reasoning/action, and credited fix commit where applicable. Record the reviewed ranges, any substitute reviewer, any later ranges closed by disposition, checks and limitations, rounds used/budget, and the reason to stop or continue. Identify genuine unresolved defects and required user decisions separately from rejected suggestions. List verified pre-existing defects in their own group, each with its location and failure scenario, and state that this change neither caused nor fixed them.
