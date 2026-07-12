---
name: orchestrate-work-campaigns
description: Coordinate complex, multi-part work as an inspectable campaign of parent and child issues, user-visible Codex tasks, isolated worktrees, evidence-backed decisions, integration stages, and final validation. Use when Codex needs to orchestrate several related issues or experiments across areas such as refactoring, reliability, security, documentation, migrations, releases, testing, performance, or technical debt; when the user asks for a controller task, issue with subissues, parallel or serialized delivery campaign, dependency ledger, or reusable multi-task workflow.
---

# Orchestrate Work Campaigns

Turn a broad objective into a controlled campaign whose tasks, authority, evidence, dependencies, and final state remain visible to the user.

## Establish Authority

1. Read repository and global instructions first.
2. Before acting, create an authority-trigger matrix. For each action, record:

   - its authority source and activation trigger;
   - the authorized actor or identity;
   - prerequisites and evidence that must be refreshed;
   - its current status and stop or revocation conditions.
3. Separate authorization to design the campaign, write tracker state, create visible tasks or worktrees, implement, commit, publish draft branches or PRs, request or record review, mark work ready, accept campaign results, merge or enable auto-merge, deploy or release, message people, administer settings, and delete or clean up resources. Never treat one as authorization for another.
4. An applicable repository instruction may supply standing, action-specific authority and name the live condition that activates it. Use that trigger only when no higher-priority instruction reserves the action and every condition is verified against the exact current artifact version.
5. Keep authority, triggers, and gate satisfaction distinct. Authorization permits an action, a trigger activates authority already declared by an applicable instruction, and a gate proves its prerequisites. None substitutes for another.
6. Treat question-form and design-only requests as proposals until the user explicitly authorizes action.
7. Use user-visible Codex tasks only when the user authorizes task creation. Use project worktrees for repository-scoped implementation tasks.
8. State terminal restrictions in the controller prompt, such as no merge, deployment, deletion, or auto-merge without action-specific authority and satisfaction of any applicable activation trigger.

## Extract Live Repository Policy

Before decomposing or launching work, build a live repository execution profile. Record each source, its scope and precedence, the exact ref or version inspected, the consequence for this campaign, and the points where it must be refreshed.

Extract the applicable:

- canonical contracts, invariants, ownership boundaries, forbidden coupling, and change-amplification rules;
- required base refresh, fallback-base policy, worktree and branch ownership, shared-file locks, and clean-state requirements;
- issue hierarchy, commit segmentation, branch and PR topology, actor identities, secret-handling rules, review protocol, checks, readiness criteria, and merge or delivery triggers;
- mandatory collateral documentation, validation commands, retry semantics, contamination rules, and compatibility coverage;
- approved locations and retention rules for committed artifacts, disposable evidence, reusable knowledge, private data, and runtime state;
- dynamic state that must be rechecked before publication, readiness, acceptance, merge, deployment, deletion, or notification.

Derive campaign rules from this profile rather than copying repository-specific values into the reusable skill. Re-read applicable sources when their ref changes, the accepted state advances, or a terminal gate is approached. If instructions conflict or terminal authority remains unclear, stop at an approval checkpoint.

## Model the Campaign

Create one parent objective and bounded child work items. Each child should have one independently reviewable outcome, explicit scope, evidence requirements, acceptance criteria, and known risks.

Before execution, define:

- the original baseline or starting state;
- the current accepted integration state;
- dependency-safe child order;
- which children can run concurrently;
- shared resources that require an exclusive slot, such as a benchmark host, database, environment, release train, CI capacity, or stakeholder review;
- required validation and final deliverables;
- the repository-driven delivery topology, including task and worktree ownership, branch bases, commit boundaries, delivery units, integration method, and merge order;
- the outcome vocabulary appropriate to the domain.

Prefer a native parent/subissue hierarchy when the tracker supports it. Keep implementation approval visible on each child rather than implying that issue creation authorizes execution.

Choose explicitly among independent common-base branches, genuine dependency stacks, repository-required integration branches, validation over the accepted repository state, or an allowed consolidated delivery. Record exact bases, refresh, rebase or retarget behavior, fallback or stop rules, shared-path ownership, cross-stack validation, merge order, and when the accepted state may advance. Do not manufacture shared abstractions, integration branches, or combined PRs that repository policy does not require.

Keep a child's recommendation, campaign acceptance, advancement of the accepted integration state, and external merge or deployment as separate decisions. An `ACCEPT` recommendation supplies evidence; it does not perform any later transition.

When a child changes a shared contract or interface, pause for a change-amplification checkpoint. Enumerate every obligated implementation, document the fan-out and shared-file impact, and obtain any additional authority required before expanding beyond the approved scope.

Amplify each child contract after orientation and before writes, then again before publication or a terminal gate. Newly discovered policy may narrow scope, add locks, strengthen validation, or add restrictions; it may not broaden authority, owned paths, external effects, or claims without a new controller decision and any additional authorization.

## Run a Controller Task

When authorized, create one user-visible controller task using the template in [controller-template.md](references/controller-template.md). The controller coordinates rather than implementing child scopes in its own checkout.

Require the controller to:

1. Inspect live repository, tracker, task, process, and external-system state.
2. Create a durable ledger and publish a concise tracker view.
3. Start each child from the exact input state declared by the repository-driven topology.
4. Create a separate visible, worktree-backed task with a self-contained prompt for every implementation, experiment, integration, and final-review stage.
5. Audit each terminal handoff before changing the accepted state or starting a dependent child.
6. Preserve unrelated work and avoid duplicate tasks, branches, jobs, or experiments.

Do not use hidden subagents for work the user expects to inspect or intervene in. Keep controller-side activity read-only while a child owns an exclusive resource slot.

When instantiating the controller template, replace any generic accepted-state, integration-stage, publication, or readiness default with the declared live topology and gate-specific requirements. Do not carry an incompatible template default into a child contract.

## Define the Child Contract

Every child prompt should include:

- objective, non-goals, and exact issue scope;
- starting branch/ref or accepted SHA;
- dependencies and inputs;
- authorized writes and forbidden external actions;
- required implementation or investigation steps;
- evidence and validation matrix;
- artifact, log, or raw-data locations;
- required branch/commit/PR behavior;
- a structured terminal handoff.

Use domain-appropriate outcomes. A useful default is:

- `ACCEPT`: include the result because it directly advances the objective;
- `ACCEPT ENABLER/NEUTRAL`: include it for correctness, maintainability, portability, reproducibility, or risk reduction without claiming the primary benefit;
- `REJECT`: evidence shows the tradeoff or regression is unacceptable;
- `INCONCLUSIVE/DEFER`: evidence is insufficient or an external dependency prevents a sound decision.

Never upgrade an unsupported observation into a claim. Preserve rejected and inconclusive evidence instead of silently dropping it.

## Control Execution

Serialize tasks that compete for a shared measurement or mutation surface. Parallelize only truly independent read-only or isolated work when the repository instructions and user authorization permit it.

For long-running local processes:

- use the managed-jobs skill;
- reconcile after restarts;
- prove an equivalent job is not already active;
- retain logs and job identifiers;
- invalidate evidence affected by contamination, interruption, or harness defects.

For each child transition:

1. Verify the starting state and resource lock.
2. Mark the child active and link its visible task.
3. Monitor without duplicating its work.
4. Audit its diff, evidence, validation, clean state, and recommendation.
5. Record the decision and exact accepted state.
6. Start dependents only after the audit is complete.

## Integrate and Validate

Follow the repository-driven delivery topology. Do not combine child branches opportunistically or create an integration branch by default. Use separate visible integration tasks when dependency, risk, policy, or delivery semantics require them; use validation over the accepted repository state when that is the defined integration model.

Keep repository delivery gates distinct, using domain-equivalent transitions when no PR exists:

- **Draft publication:** the authorized branch or artifact is published in its preliminary review state.
- **Child readiness:** the exact child head has required validation, review, and finding triage and may be marked ready when authorized.
- **Campaign acceptance:** the audited result is accepted for integration after required combined or current-state validation.
- **Merge or delivery:** exact-head approvals, checks, repository triggers, and merge or delivery authority are revalidated immediately before the terminal action.

For every gate, record the authority source, actor, exact artifact version, required evidence, and live state to refresh. Passing one gate never crosses another implicitly.

Complete repository-defined final validation that compares the original baseline with the complete accepted result and exercises the full compatibility contract. Use a separate final-stack task when topology, risk, or authorization requires it; otherwise validate over the accepted repository state. If interactions fail, bisect accepted changes, remove offenders, update their decisions, and rerun affected validation.

Create a separate adversarial-review task when risk justifies it. Review the implementation, evidence quality, cross-change interactions, operational behavior, and hidden regressions. Resume the same review sessions for fix verification when the review tool supports it.

Cross a delivery gate only when its exact artifact meets that gate's repository-derived minimum evidence and the action is authorized. Draft publication need not satisfy later readiness or acceptance gates. Require combined validation and finding closure at the gates whose live policy requires them. After a terminal delivery action, verify the exact landed state and record the resulting accepted state and evidence.

## Maintain the Ledger

Keep the parent tracker and durable ledger synchronized with:

- child order, dependencies, and resource locks;
- issue, visible task, worktree, branch, commit, and PR links;
- original and current accepted states;
- status, decision, evidence location, and limitations;
- validation and review results at exact artifact versions;
- final impact table and recommended delivery order.

End with a concise report covering every child, accepted and excluded work, regressions, limitations, evidence locations, exact deliverables, and any remaining user decision.
