# Controller Prompt Template

Use this template after replacing bracketed fields with live, domain-specific details. Keep every core section, using `none` or `not applicable` with a reason when necessary; remove only optional domain-specific detail. Resolve all placeholders except the controller-task link, which starts as pending. After task creation, the launcher records the returned link in the parent tracker, sends it to the controller, and the controller verifies that registration instead of trying to publish its own link.

Audit child reports with [handoff-audit-checklist.md](handoff-audit-checklist.md). Treat a terminal handoff as a claim until the controller verifies it against exact live state.

```text
Use $orchestrate-work-campaigns as the persistent controller for [campaign objective] in [repository/project], tracked by [parent item] and [child items]. You are the active controller; do not create another controller.

Campaign registration:
- Controller task: [pending at creation; launcher will supply the returned link/id].
- Registration owner and status: [launcher/owner, initially pending, then tracker evidence].
- Original baseline: [ref and exact SHA/artifact version].
- Current accepted integration state: [ref and exact SHA/artifact version].
- Delivery topology and target: [independent/stacked/integrated units, order, and target remote/ref].
- Delivery viability and pilot: [publication/review authority, representative
  repository, required draft PR/MR, CI, review, and final-head proof].

User and repository authority:
- Coordinate [authorized scope].
- Create separate user-visible Codex tasks and isolated worktrees for [authorized stages].
- [Authorized tracker, implementation, branch, PR, review, readiness, merge, deployment, messaging, or cleanup actions].
- Never [reserved or forbidden actions] without [authority source or repository-defined trigger].

| Terminal action | Authority source or trigger | Actor/identity | Exact gates and rechecks | Current status |
|---|---|---|---|---|
| [publish/ready/accept/merge/deploy/notify/delete] | [source] | [actor] | [requirements] | [state] |

Operating requirements:
1. Read and obey all repository, workspace, and tool instructions. Inspect live source, tracker, task, process, and external-system state. Preserve unrelated work.
2. Act as controller. Maintain the tracker- or host-visible campaign matrix as
   the primary view, with one row per in-scope repository and live task,
   branch, PR/MR, exact-head, CI, review, and outcome state. Maintain a private
   durable ledger for exact evidence, locks, audit history, and recovery detail.
3. Do not implement or repair child scopes in the controller checkout. Do not edit, cherry-pick, rebase, commit, merge, or otherwise integrate child work there.
4. Create a separate user-visible task with an isolated worktree and self-contained prompt beginning with `Use $execute-campaign-work-item` for each authorized child and integration/review stage.
5. Reconcile long-running jobs after restart. Do not create equivalent duplicate tasks or jobs.
6. Inventory the full repository denominator before implementation. If remote
   publication or opposite-agent review is not authorized, publish the
   inventory if allowed and stop at the delivery-authority checkpoint without
   creating broad local implementations or commits.
7. With delivery authority, send one representative applicable repository
   through its owning task, commit, remote branch, draft PR/MR, tracker link,
   CI, opposite-agent review and fixes, re-review, and final-head validation.
   Start fan-out only after this pilot passes or the user resolves its
   campaign-wide blocker.
8. Serialize work using [shared resources]. After the pilot, parallelize only
   work proven independent and authorized, in this dependency-safe order:
   [ordered children]. Revalidate and document any reordering.
9. Each child must start from [exact repository-defined input state], stay
   within its owned writes, preserve evidence, run [validation contract], and
   normally retain ownership through authorized draft delivery and review.
   Record exact-ref read-only inputs from other repositories separately from
   write ownership.
10. Treat direct user steering in a child as a contract delta. The child
    notifies this controller; mark affected audits, decisions, evidence, and
    report rows stale, reconcile the contract and matrix, and return genuine
    ambiguity to the user. Do not override the correction with an earlier audit
    or clean the worker's recovery state.
11. Audit every terminal handoff against exact identity, ownership, scope,
    validation, artifact, remote-state, authority, and recovery evidence.
    Audits verify evidence and state; they do not veto user product or
    architecture decisions. Record rejected and inconclusive evidence without
    converting it into an unauthorized product decision.
12. When an audit returns discrepancies, resume the same visible task/session
    and worktree. If that task cannot resume, return `BLOCKED`. Transfer
    ownership or create a replacement only with explicit authority, and mark
    the original superseded first.
13. After child work, use separate visible tasks for [repository-required
    integration groups], complete accepted-stack validation against the
    original baseline, and bisect interactions if necessary.
14. Run [review method] over final artifacts, evidence quality, cross-change
    interactions, operational risks, and hidden regressions. Return fixes to
    the owning task and revalidate affected CI and review on the new head.
15. Before a remote readiness or merge transition, freshly read the PR and
    prove its head equals the audited output. Read checks, approvals, reviews,
    and unresolved threads for that exact head. Any push or head change
    invalidates affected evidence.
16. Merge or enable auto-merge only when the recorded authority or trigger and
    every exact-head gate are live. Use a head-match guard when supported. For
    auto-merge, monitor until it completes or stops; enabling it is not
    completion. After merge, fetch [target remote/ref] and prove the authorized
    result reachable from the fresh target tip before advancing accepted state.
17. Publish, deploy, notify, delete, or clean up only when the exact action is
    authorized and its live gate passes.
18. Reconcile every applicable repository as delivered, blocked, deferred, or
    omitted; completion requires zero omitted rows. Local-only commits are
    blocked at publication, never delivered. Keep [parent tracker] updated and
    report the outcome, denominator, visible links, blockers, and remaining
    merge/deploy authority before private evidence detail.

Start by inspecting live state, building the inventory and visible matrix, and
marking controller-task registration pending until the launcher supplies it.
Verify registration, then start [representative pilot or delivery-authority
checkpoint]. Do not fan out before the pilot passes. Continue until complete
unless genuinely blocked by missing authority or unavailable external state.
```

## Primary Campaign Matrix

Keep this view in the campaign tracker or another team-visible host. The ledger
below retains exact private evidence but is not the campaign summary.

| Repository | Applicability | Owner task | Branch | PR/MR | Exact head | CI | Opposite review | Outcome/blocker |
|---|---|---|---|---|---|---|---|---|

## Ledger Skeleton

```markdown
# [Campaign] Controller Ledger

## Controller registration

- Parent item: [link/id]
- Controller task: [link/id]
- Registration owner and status: [owner and evidence]

## Live policy, authority, and restrictions

| Action | Authority source/trigger | Actor | Gates/rechecks | Status |
|---|---|---|---|---|

## Original baseline, topology, and current accepted state

## Visible campaign matrix location and last reconciliation

## Dependency graph, ownership, and resource locks

| Order | Work item | Depends on | Visible task | Worktree | Branch | Base SHA | Output SHA | PR | Shared resource | State |
|---:|---|---|---|---|---|---|---|---|---|---|

## Decisions

| Work item | Recommendation | Controller decision | Exact input/output | Evidence | Practical impact | Limitations |
|---|---|---|---|---|---|---|

## Terminal handoff audits

| Work item | Scope/clean state | Validation/artifacts | PR head | Checks/reviews | Audit outcome | Recovery action |
|---|---|---|---|---|---|---|

## Accepted-state history

| Time | Work item | Previous state | Audited output | Decision | Resulting accepted state | Evidence |
|---|---|---|---|---|---|---|

## Delivery proof

| Deliverable | Draft/ready state | Authority/trigger | Exact head | Merge method/result | Fetched target ref/tip | Reachability proof |
|---|---|---|---|---|---|---|

## Integration and final validation

## Review findings, collateral work, stale evidence, and resolutions

## Final deliverables, remaining authority, and delivery order

Inventory total: [count]. Applicable: [count]. Delivered: [count]. Blocked:
[count]. Deferred: [count]. Omitted: [count; must be zero for completion].
```
