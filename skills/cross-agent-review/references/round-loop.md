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

## Carry unresolved findings forward

An unresolved in-scope finding is one you did not fix: plausible ones you left,
false positives, and confirmed ones you ruled out of task scope. Later rounds
see only repair commits, so restate each unresolved finding in the next focus
file with your reasoning and ask the reviewer to accept or contest it.

A finding is resolved when it is fixed, when the reviewer accepts your reasoning,
or when it is escalated to the user.

## Decide on another round

Review starts with a budget of three successful, correctly scoped rounds. Each
such round consumes one. Failed or scope-invalid runs consume nothing.

A direct user request to run another review round adds one to the budget and
requests that round. It runs without a reviewer vote or implementer decision. A
request to increase the budget by N adds N without by itself requesting a run.
Completed rounds remain counted; the implementer cannot reset or increase the
budget.

For agent-initiated continuation:

1. Continue only when the current round produced a confirmed finding and its fix
   changed the diff.
2. Require remaining budget. If none remains, ask how many rounds the user wants
   to add; a positive whole-number answer adds that amount.
3. Ask for the reviewer's vote inside the review that already runs. Record an
   absent or unparseable vote instead of inferring one.
4. The implementer decides. Report any decision to stop against a reviewer vote
   to continue.
5. Escalate a finding that survives two rounds of disagreement.

Small or low-risk changes normally finish in one round. Round 3 is an escape
hatch under the initial budget.

## Escalate instead of swallowing

| Situation | Why the loop cannot resolve it | Required action |
| --- | --- | --- |
| No-diff stop leaves an unresolved finding | The required later-round base equals `HEAD`, so there is no repair range | Escalate in that round |
| Confirmed but outside task scope | It produces no authorized repair diff | Escalate; a verified defect must not pass silently |
| No reviewer path can enforce the later-round range | A full re-audit can invent findings in unchanged material | Stop and ask the user how to proceed |
| A commit landed after the last completed review and no next round is permitted | The current head remains unreviewed | Block the handoff and escalate |

## Post-review commits block the handoff

Any commit after the last completed review makes the change not review-complete
until a successful scoped round reviews that range. Do not mark the change ready,
done, or reviewed while its head is unreviewed. If no next round is permitted,
escalate with the exact unreviewed commits; higher-precedence repository policy
decides whether explicit risk acceptance is allowed.

## Report contract

1. A table: severity | file:line | class | action | fix commit.
2. Every reviewed `base..head`, its scope, and whether it consumed budget.
3. Rounds used / current budget, every user-authorized increase, and why the loop
   stopped.
4. Every rejected scope violation and the reason the current range did not cause
   it.
5. Commits after the last completed review, named and declared unreviewed.
6. Reviewer-versus-implementer vote disagreements and rounds with no usable vote.
7. Every unresolved finding, with its class and why it was left.
8. Validation commands that ran, and any that could not run and why.
