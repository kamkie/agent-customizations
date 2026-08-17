---
name: execute-campaign-work-item
description: Execute one bounded repository-owned campaign work item from an exact accepted input through implementation, validation, authorized draft publication, CI, opposite-agent review and fixes, final-head verification, and a concise evidence-backed handoff. Use only when the task contains an explicit campaign child contract, including later direct-user contract deltas. Do not design campaigns, create sibling tasks, coordinate multiple work items, accept campaign state, or capture ordinary standalone work.
---

# Execute Campaign Work Item

Own exactly one controller-assigned contract. Repository and user instructions
remain authoritative; this skill supplies no additional permission.

## Validate the Contract Before Writes

Proceed only when the task states all of the following:

- policy sources, their consequences, precedence, and refresh points;
- one objective, acceptance criteria, non-goals, and owned and forbidden paths;
- exact accepted base ref and SHA or artifact version, refresh steps,
  dependencies, exact-ref read-only inputs, worktree and branch owner, and
  shared locks;
- authorized writes and external actions, required actor identities, gates, and
  explicitly forbidden actions;
- required work, collateral documentation, validation and evidence, artifact
  placement, delivery behavior, stop conditions, and terminal handoff fields.

Treat unlisted external actions and scope as unauthorized. If the base,
ownership, scope, lock, authority, or required evidence is missing or ambiguous,
return `BLOCKED` before editing and identify the exact controller decision
needed.

## Apply Direct User Steering

Treat a direct user instruction in this worker as a contract delta that
supersedes stale controller decisions unless higher-priority safety or policy
conflicts. Notify the controller immediately with the exact delta and identify
audits, decisions, validation, and delivery state that are now stale. Continue
when the user instruction resolves scope and authority unambiguously, after
refreshing shared locks and resource ownership. If the delta touches a
serialized surface, obtain or reconfirm the same campaign lock before acting;
controller coordination may sequence the work but may not override the user's
decision. Return remaining ambiguity or conflict to the user instead of letting
the controller silently narrow or override it.

Do not stop, discard recovery artifacts, or preserve a prior `DEFER` merely to
protect the original contract. A maintained applicable repository's recoverable
product, test-bootstrap, or schema defect is work to address when the current
user-authorized outcome and owned write paths cover it. Otherwise preserve the
state and report the exact additional write scope or authority required.

## Execute the Common Path

1. Read every applicable instruction source and record the exact version or
   scope inspected. Newly discovered policy may narrow work or strengthen
   validation; it may not broaden authority or owned paths.
2. Refresh the assigned base and prove the current worktree, branch, HEAD,
   upstream, clean state, dependencies, and locks match the contract exactly.
   Stop on a dirty, stale, detached, multiply owned, or mismatched state instead
   of repairing or replacing it silently.
3. Perform only the assigned work using the smallest coherent diff. Preserve
   unrelated work. Limit writes to the owned repository and paths. You may read
   a verified exact ref or artifact from another repository as an authoritative
   input without taking write ownership; record its repository, exact version,
   provenance, and purpose. Do not create sibling tasks, change campaign
   topology, integrate other workers, or advance the controller's accepted
   state.
4. Use the repository-required durable process mechanism for long-running work.
   Reuse an equivalent active process and preserve logs, failed attempts,
   interruptions, and contaminated evidence under the contract's retention
   rules.
5. Run the directly required validation against the exact output. Follow the
   stated retry and contamination rules; rerun every check invalidated by a
   changed input. Keep claims bounded by the evidence.
6. When authorized, the repository owner normally continues the same work item
   through local preflight, commit, remote branch, draft PR/MR, tracker link,
   CI, required opposite-agent review, finding fixes, re-review, and final-head
   validation. Do not hand these ordinary delivery stages to replacement owners.
   Recheck live policy, actor, exact head, gates, and unresolved feedback before
   each terminal action. Treat any post-review commit as invalidating affected
   CI and review evidence.
7. Perform merge, deployment, notification, deletion, or cleanup only when the
   current contract or later direct user instruction explicitly authorizes that
   action and every repository gate passes. Publication authority alone never
   supplies merge or deployment authority.
8. Inspect the final diff and worktree state, retain exact evidence in the
   approved private location, and return the concise handoff below. Do not
   declare campaign acceptance or start dependent work. A local-only commit is
   not delivered or complete delivery.

## Return the Terminal Handoff

```text
Outcome: [COMPLETE/BLOCKED and ACCEPT/ACCEPT ENABLER/NEUTRAL/REJECT/INCONCLUSIVE/DEFER, with impact].
Deliverable: [exact input/output, remote branch, PR/MR, head, CI and review].
Delivery state: [performed and withheld external actions, readiness,
merge/deploy, and integration state].
Scope: [owned diff, write ownership, read-only inputs, unrelated preservation].
Validation: [result summary and private exact-evidence location].
Evidence: [artifacts/retention, worktree/clean state/locks, policy rechecks,
performed and withheld external actions in the private record].
Limitations: [blocker, stale evidence, deviations, or none].
Next: [specific controller action and remaining authority].
```

Return evidence and a recommendation only. The controller owns handoff audit,
campaign acceptance, accepted-state advancement, and dependent task creation.

Read [exceptional-recovery.md](references/exceptional-recovery.md) only when the
assigned state is mismatched, validation is contaminated or contradictory, a
correction must resume after `RETURN`, or the assigned task cannot continue.
