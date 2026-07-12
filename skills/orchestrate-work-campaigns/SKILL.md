---
name: orchestrate-work-campaigns
description: Coordinate an authorized multi-part campaign through one visible controller, bounded worker tasks, an evidence ledger, audited handoffs, integration, and final validation. Use for parent/child issue campaigns, dependency-led parallel or serialized delivery, or an explicit controller task. Do not use for a single work item, ordinary multi-file implementation, simple delegation, or review-only coordination.
---

# Orchestrate Work Campaigns

Act only as the campaign bootstrap or controller. Never implement, repair, or
integrate a worker's owned scope in the controller checkout.

## Run the Common Path

1. **Confirm fit and authority.** Read the active repository and global
   instructions. Use a campaign only for several bounded delivery or experiment
   units whose dependencies, ownership, evidence, or integration require one
   coordinating state. Record which actions are authorized now and which remain
   conditional or forbidden.
2. **Establish one controller.** If this is already the explicitly assigned
   controller task, do not create another. Otherwise, create exactly one visible
   project task with an isolated worktree only when task creation is authorized.
   Record the returned task and worktree before launching workers. If a separate
   controller is required but unauthorized, stop at a proposal or approval
   checkpoint.
3. **Build the live execution profile.** Record instruction sources and exact
   versions, original baseline, current accepted state, topology, dependencies,
   shared locks, validation contract, delivery gates, actor identities, and
   policy refresh points. Discover repository-specific values at runtime.
4. **Create the ledger.** Track every work item, visible task, worktree, branch,
   exact input and output, lock, evidence location, decision, review, delivery
   state, and accepted-state transition. Reconcile live tasks, jobs, branches,
   and PRs before creating replacements or filling free slots.
5. **Launch bounded workers.** Create a separate visible, worktree-backed task
   for each authorized implementation, investigation, integration, or final
   review unit. Begin each prompt with `Use $execute-campaign-work-item` and
   include the complete contract below; never rely on the worker reading this
   coordinator skill or its references. Do not substitute hidden subagents for
   work the user expects to inspect or interrupt.
6. **Control execution.** Serialize shared mutation or measurement surfaces.
   Parallelize only proven-independent work. Monitor without duplicating worker
   activity, preserve failed or contaminated evidence, and resume the same task
   and worktree for corrections whenever possible.
7. **Audit each handoff.** Verify task/worktree ownership, exact input and
   output, complete diff, scope, clean state, validation, artifacts, locks, and
   remote head. Return discrepancies to the same worker. Accept, exclude, or
   defer a verified recommendation separately from any readiness, merge, or
   deployment action.
8. **Integrate and finish.** Follow the repository-defined topology; do not
   invent an integration branch or combined PR. Run final validation over the
   complete accepted state, resolve interaction failures through owning workers,
   and report exact deliverables, excluded work, limitations, remaining
   authority, and next action.

## Create the Controller Prompt

Use this compact prompt when creating a separate controller task:

```text
Use $orchestrate-work-campaigns as the active controller for [objective] in
[repository/project]. Do not create another controller and do not implement
worker scopes in this checkout.

Registration: [parent item, controller task pending, registration owner].
Authority: [authorized actions, actors, activation triggers, forbidden actions].
State: [original exact baseline, accepted state, topology, dependencies, locks].
Workers: [bounded items, order, concurrency, required visible tasks/worktrees].
Evidence: [ledger location, validation, artifacts, outcomes, refresh points].
Delivery: [draft/readiness/acceptance/merge/deploy gates and current authority].

Inspect live state, register this controller, create the ledger, then start only
the first authorized worker or approval checkpoint. Continue until the campaign
is complete or genuinely blocked.
```

For a campaign with extensive tracker registration or terminal-delivery gates,
read [controller-template.md](references/controller-template.md) before creating
the controller task.

## Create Each Worker Contract

Every worker prompt must resolve all fields in this contract:

```text
Use $execute-campaign-work-item to execute this assigned campaign contract.
Work item: [one independently reviewable outcome and tracking item].
Policy: [sources, consequences, precedence, and refresh points].
Scope: [objective, acceptance criteria, non-goals, owned and forbidden paths].
Starting state: [exact base ref and SHA, refresh steps, dependencies, locks].
Authority: [allowed writes/external actions, actors, gates, forbidden actions].
Required work: [implementation/investigation and collateral documentation].
Validation: [commands or methods, expected results, evidence, retry rules].
Artifacts: [destinations, privacy, retention, cleanup or promotion rules].
Delivery: [commit, branch, publication, review, readiness, merge restrictions].
Stop conditions: [ambiguity, expansion, contamination, unavailable authority].
Handoff: [execution state, outcome, exact input/output, diff, validation,
artifacts, ownership, external actions, PR state, limitations, next action].
```

Use `none` or `not applicable` with a reason where appropriate. Never launch a
contract with unresolved placeholders. For complex validation, delivery, or
artifact matrices, read
[child-contract-template.md](references/child-contract-template.md).

## Audit and Recover

A worker report is a claim until verified against exact live state. Use
`VERIFIED`, `RETURN`, or `BLOCKED` for the audit result; keep it separate from
the worker's campaign recommendation. Do not advance accepted state or start a
dependent worker before verification.

Read [handoff-audit-checklist.md](references/handoff-audit-checklist.md) when a
handoff has discrepancies, moving remote state, a terminal delivery action, or
ownership recovery. Do not create a replacement task, worktree, branch, job, or
PR without authority; mark the original superseded before transferring
ownership.
