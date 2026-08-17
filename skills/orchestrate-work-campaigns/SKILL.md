---
name: orchestrate-work-campaigns
description: Coordinate an authorized multi-part delivery campaign through one visible controller, bounded delivery-unit owner tasks, tracker-visible delivery state, a representative pilot, CI, opposite-agent review, audited handoffs, and final validation. Use when the user says "Start delivery campaign TRACKER", for parent/child issue campaigns, dependency-led delivery, or an explicit controller task. Do not use for a single work item, ordinary multi-file implementation, simple delegation, or review-only coordination.
---

# Orchestrate Work Campaigns

Act only as the campaign bootstrap or controller. Never implement, repair, or
integrate a worker's owned scope in the controller checkout.

Treat each repository as a delivery unit in a multi-repository campaign. In a
single-repository campaign, use each independently reviewable outcome as the
delivery unit. Apply the pilot, visible matrix, and denominator per unit.

## Run the Common Path

1. **Confirm fit and authority.** Read the active repository and global
   instructions. Use a campaign only for several bounded delivery or experiment
   units whose dependencies, ownership, evidence, or integration require one
   coordinating state. Resolve the authority for inventory, task/worktree and
   branch creation, commits, publication, tracker updates, CI, review, merge,
   and deployment. Never infer merge or deployment authority from publication.
2. **Establish one controller.** If this is already the explicitly assigned
   controller task, do not create another. Otherwise, create exactly one visible
   project task with an isolated worktree only when task creation is authorized.
   Record the returned task and worktree before launching workers. If a separate
   controller is required but unauthorized, stop at a proposal or approval
   checkpoint.
3. **Build the live execution profile and inventory.** Record instruction
   sources and exact versions, original baseline, current accepted state,
   topology, dependencies, shared locks, validation contract, delivery gates,
   actor identities, policy refresh points, and the full in-scope delivery-unit
   denominator. Discover repository-specific values at runtime.
4. **Create the primary campaign view.** Maintain a tracker- or host-visible
   matrix with one row per in-scope delivery unit and columns for applicability,
   owner task, branch, PR/MR, exact head, CI, opposite review, and outcome or
   blocker. Keep a private ledger for exact evidence, locks, and audit history;
   it is secondary and must not replace team-visible delivery state. Reconcile
   live tasks, jobs, branches, and PRs before creating replacements.
5. **Pass the delivery-viability gate.** Before broad implementation, confirm
   that authority, actor identities, host access, tools, and repository policy
   allow one owner to attempt local preflight, commit, remote branch, draft
   PR/MR, tracker link, repository CI (or explicit evidence that none exists),
   required opposite-agent review, finding fixes and re-review, and final-head
   validation. The representative pilot in step 6 supplies the live delivery
   proof; do not run a duplicate pilot here. If publication or review authority
   is absent, finish the bounded inventory and stop at a delivery-authority
   checkpoint. Do not fan out implementation or accumulate hidden local commits.
6. **Deliver one representative pilot.** Select one typical applicable delivery
   unit and create its visible owner task with a complete contract. Audit
   it through draft PR/MR, CI, opposite-agent findings and fixes, re-review, and
   final-head validation. Do not fan out until this proves the delivery path or
   exposes a campaign-wide blocker. A local commit is not a successful pilot.
7. **Launch bounded workers.** After the pilot gate passes, create a separate
   visible, worktree-backed task for each authorized implementation,
   investigation, integration, or final-review unit. Begin each prompt with
   `Use $execute-campaign-work-item` and include the complete contract below;
   never rely on the worker reading this coordinator skill or its references.
   Do not substitute hidden subagents for inspectable work.
8. **Control execution and steering.** Serialize shared mutation or measurement
   surfaces and parallelize only proven-independent work. Treat a direct user
   instruction in any worker as a contract delta that supersedes stale
   controller decisions unless it conflicts with higher-priority safety or
   policy. Require the worker to notify the controller, mark affected audits,
   decisions, and evidence stale, and reconcile the matrix and contract. Return
   ambiguity to the user; do not override the user, stop the worker, or clean
   its recovery state from an earlier audit.
9. **Audit each handoff.** Verify identity, ownership, exact inputs and outputs,
   diff, validation, artifacts, locks, delivery authority, and live remote head.
   Audit establishes evidence and state; it does not veto or reinterpret user
   product or architecture decisions. Return discrepancies to the same worker
   and re-audit every head changed by fixes.
10. **Integrate and finish.** Follow the repository-defined topology; do not
    invent an integration branch or combined PR. Resolve interaction failures
    through owning workers. Reconcile applicable delivery units so delivered,
    blocked, deferred, and omitted equal the applicable count; completion
    requires `omitted = 0`. Count a delivery unit
    as delivered only when its team-visible artifact reaches the contract's CI,
    review, and final-head state; classify local-only commits as blocked at
    publication. Report the outcome and denominator first, then concise links,
    blockers, limitations, remaining merge/deploy authority, and next action.

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
Evidence: [primary visible matrix, private ledger, validation, refresh points].
Delivery: [viability gate, pilot, CI/review, final-head, merge/deploy authority].

Inspect live state, register this controller, build the inventory and visible
matrix, then run only the delivery pilot or authority checkpoint. Continue
through fan-out only after the pilot passes.
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
Read-only inputs: [other repositories/artifacts, exact refs/versions, purpose].
Authority: [allowed writes/external actions, actors, gates, forbidden actions].
Required work: [implementation/investigation and collateral documentation].
Validation: [commands or methods, expected results, evidence, retry rules].
Artifacts: [destinations, privacy, retention, cleanup or promotion rules].
Delivery: [commit, branch, publication, review, readiness, merge restrictions].
Stop conditions: [ambiguity, expansion, contamination, unavailable authority].
Handoff: [outcome/impact, exact input/output and delivery head, performed and
withheld actions plus integration state, owned diff and read-only inputs,
validation/evidence, limitations, next action and authority].
```

Keep writes within the owned repository and paths. Exact-ref, read-only inputs
from another repository are valid dependencies when provenance and purpose are
recorded; they do not transfer write ownership.

Use `none` or `not applicable` with a reason where appropriate. Never launch a
contract with unresolved placeholders. For complex validation, delivery, or
artifact matrices, read
[child-contract-template.md](references/child-contract-template.md).

## Audit and Recover

A worker report is a claim until verified against exact live state. Use
`VERIFIED`, `RETURN`, or `BLOCKED` for the audit result; keep it separate from
the worker's campaign recommendation. Do not advance accepted state or start a
dependent worker before verification.

Before relying on an audit, check for later direct user steering in the worker.
Invalidate stale audit decisions and recover through the same owner task.

Read [handoff-audit-checklist.md](references/handoff-audit-checklist.md) when a
handoff has discrepancies, moving remote state, a terminal delivery action, or
ownership recovery. Do not create a replacement task, worktree, branch, job, or
PR without authority; mark the original superseded before transferring
ownership.
