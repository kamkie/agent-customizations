# Round loop, escalation, and report contract

Load this when a round returns findings. The entrypoint covers running a round;
this covers deciding what happens next.

## Classify every finding yourself

Do not accept the reviewer's verdict. Read the code behind each finding.

| Class | Meaning | Action |
| --- | --- | --- |
| confirmed | You verified the defect is real | Fix it, or escalate if out of scope |
| plausible | Could be real, not cheaply verifiable | Fix only if small, safe, obviously harmless |
| false positive | You can state a one-line reason it is wrong | Never "fix" it |

## Carry unresolved findings forward

An unresolved finding is any finding you did not fix: plausible ones you left,
false positives, and confirmed ones you ruled out of scope.

On a reviewer that takes an explicit range, later rounds see only the fixes, so
an unfixed finding leaves the diff and cannot be raised again. Restate each one
in the next round's focus text with your reasoning, and ask the reviewer to
accept or contest it.

A finding is resolved when it is fixed, when the reviewer accepts your reasoning,
or when it is escalated to the user.

## Decide on another round

Rounds are bounded at three and never automatic.

1. A next round happens only when this round produced a confirmed finding **and**
   the fixes changed the diff.
2. Both sides vote. Ask for the reviewer's vote inside the review that already
   runs. When no usable vote comes back, record the absence; never infer one from
   the verdict.
3. **The implementer decides.** If the reviewer voted to continue and the
   implementer stops, say so explicitly in the report.
4. A finding surviving two rounds of disagreement is escalated, not re-litigated.

Small or low-risk changes finish in one round. Round 3 is an escape hatch.

### What resets the counter

Only the user resets it. Rounds accumulate across every change an agent makes on
its own initiative, including a restructure of its own work. When the user asks
for a different shape, the counter starts over, because that is new work rather
than another repair of the same work.

An agent must never reset its own budget by reworking what it already wrote.
That loophole would make the ceiling meaningless: any implementer short of rounds
could buy three more by rewriting instead of repairing.

## Escalate instead of swallowing

| Situation | Why the loop cannot resolve it | Required action |
| --- | --- | --- |
| No-diff stop leaves any unfixed finding | Without a diff there is no next round to carry it into | Escalate to the user in that round |
| Confirmed but out of scope | Produces no repair diff, so rule 1 stops the loop | Escalate; a verified defect must not pass silently |
| Reviewer mode takes no supplementary prompt | Carry-forward text and the vote request never reach it | Escalate a disagreement immediately; no later round can retest it |
| Commit landed after the last completed review | The ceiling is reached; nothing can review it | Block the handoff (below) |

## Post-review commits block the handoff

Fixes made in the final round are not themselves reviewed. Naming them in the
report is not enough — a regression in the last repair would ship having been
merely mentioned.

When any commit lands after the last completed review, the change is **not
review-complete**. Do not mark it ready, done, or reviewed. Escalate with the
exact unreviewed commits and let the user accept the risk explicitly.

This keeps the ceiling hard. The loop still stops at three rounds; it stops as
*blocked* rather than as *finished* when the last word belonged to an unreviewed
repair.

## Report contract

1. A table: severity | file:line | class | action (fixed/skipped/escalated) |
   fix commit.
2. Rounds run, and why the loop stopped: clean round, no diff change, ceiling
   reached, or unresolved disagreement.
3. Commits that landed after the last review, named and declared unreviewed.
4. Any reviewer-versus-implementer vote disagreement, and any round with no
   usable vote.
5. Every unresolved finding, with its class and why it was left.
6. Validation commands that ran, and any that could not run and why.
