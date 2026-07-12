---
name: execute-campaign-work-item
description: Execute one bounded implementation, investigation, integration, or final-review work item assigned by a visible campaign controller, from an exact accepted input through scoped validation and an evidence-backed terminal handoff. Use only when the current task contains an explicit campaign child contract. Do not design campaigns, create sibling tasks, coordinate multiple work items, accept campaign state, or capture ordinary standalone work.
---

# Execute Campaign Work Item

Own exactly one controller-assigned contract. Repository and user instructions
remain authoritative; this skill supplies no additional permission.

## Validate the Contract Before Writes

Proceed only when the task states all of the following:

- policy sources, their consequences, precedence, and refresh points;
- one objective, acceptance criteria, non-goals, and owned and forbidden paths;
- exact accepted base ref and SHA or artifact version, refresh steps,
  dependencies, worktree and branch owner, and shared locks;
- authorized writes and external actions, required actor identities, gates, and
  explicitly forbidden actions;
- required work, collateral documentation, validation and evidence, artifact
  placement, delivery behavior, stop conditions, and terminal handoff fields.

Treat unlisted external actions and scope as unauthorized. If the base,
ownership, scope, lock, authority, or required evidence is missing or ambiguous,
return `BLOCKED` before editing and identify the exact controller decision
needed.

## Execute the Common Path

1. Read every applicable instruction source and record the exact version or
   scope inspected. Newly discovered policy may narrow work or strengthen
   validation; it may not broaden authority or owned paths.
2. Refresh the assigned base and prove the current worktree, branch, HEAD,
   upstream, clean state, dependencies, and locks match the contract exactly.
   Stop on a dirty, stale, detached, multiply owned, or mismatched state instead
   of repairing or replacing it silently.
3. Perform only the assigned work using the smallest coherent diff. Preserve
   unrelated work. Do not create sibling tasks, change campaign topology,
   integrate other workers, or advance the controller's accepted state.
4. Use the repository-required durable process mechanism for long-running work.
   Reuse an equivalent active process and preserve logs, failed attempts,
   interruptions, and contaminated evidence under the contract's retention
   rules.
5. Run the directly required validation against the exact output. Follow the
   stated retry and contamination rules; rerun every check invalidated by a
   changed input. Keep claims bounded by the evidence.
6. Perform only contract-authorized commit, push, tracker, PR, review,
   readiness, merge, deployment, messaging, or cleanup actions. Recheck live
   policy, actor, exact head, gates, reviews, and unresolved feedback immediately
   before a terminal action.
7. Inspect the final diff and worktree state, then return the structured handoff
   below. Do not declare the result accepted or start dependent work.

## Return the Terminal Handoff

```text
Execution: [COMPLETE or BLOCKED, with reason].
Outcome: [ACCEPT, ACCEPT ENABLER/NEUTRAL, REJECT, or INCONCLUSIVE/DEFER].
Recommendation and impact: [evidence-bounded conclusion].
Exact input: [ref and SHA or artifact version].
Exact output: [branch, commit/tree SHA, artifact version, or no change].
Scope and diff: [owned changes and unrelated-work preservation].
Validation: [commands/methods, results, exact tested version, evidence].
Artifacts: [locations, classification, retention, cleanup status].
Ownership and locks: [task, worktree, branch, clean state, lock release].
Policy and authority: [sources, rechecks, authorized and withheld actions].
Delivery state: [remote branch, PR, exact head, checks, reviews, approvals].
Deviations and limitations: [retries, contamination, findings, or none].
Next action: [specific controller decision], authority [present/absent].
```

Return evidence and a recommendation only. The controller owns handoff audit,
campaign acceptance, accepted-state advancement, and dependent task creation.

Read [exceptional-recovery.md](references/exceptional-recovery.md) only when the
assigned state is mismatched, validation is contaminated or contradictory, a
correction must resume after `RETURN`, or the assigned task cannot continue.
