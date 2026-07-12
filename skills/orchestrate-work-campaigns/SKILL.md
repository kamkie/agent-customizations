---
name: orchestrate-work-campaigns
description: Coordinate complex, multi-part work as an inspectable campaign of parent and child issues, user-visible Codex tasks, isolated worktrees, evidence-backed decisions, integration stages, and final validation. Use when Codex needs to orchestrate several related issues or experiments across areas such as refactoring, reliability, security, documentation, migrations, releases, testing, performance, or technical debt; when the user asks for a controller task, issue with subissues, parallel or serialized delivery campaign, dependency ledger, or reusable multi-task workflow.
---

# Orchestrate Work Campaigns

Turn a broad objective into a controlled campaign whose tasks, authority, evidence, dependencies, and final state remain visible to the user.

## Establish Authority

1. Read repository and global instructions first.
2. Separate authorization to design the campaign, create issues, start a controller task, implement children, publish branches/PRs, and merge. Never treat one as authorization for all others.
3. Treat question-form and design-only requests as proposals until the user explicitly authorizes action.
4. Use user-visible Codex tasks only when the user authorizes task creation. Use project worktrees for repository-scoped implementation tasks.
5. State terminal restrictions in the controller prompt, such as no merge, deployment, deletion, or auto-merge without separate authority.

## Model the Campaign

Create one parent objective and bounded child work items. Each child should have one independently reviewable outcome, explicit scope, evidence requirements, acceptance criteria, and known risks.

Before execution, define:

- the original baseline or starting state;
- the current accepted integration state;
- dependency-safe child order;
- which children can run concurrently;
- shared resources that require an exclusive slot, such as a benchmark host, database, environment, release train, CI capacity, or stakeholder review;
- required validation and final deliverables;
- the outcome vocabulary appropriate to the domain.

Prefer a native parent/subissue hierarchy when the tracker supports it. Keep implementation approval visible on each child rather than implying that issue creation authorizes execution.

## Run a Controller Task

When authorized, create one user-visible controller task using the template in [controller-template.md](references/controller-template.md). The controller coordinates rather than implementing child scopes in its own checkout.

Require the controller to:

1. Inspect live repository, tracker, task, process, and external-system state.
2. Create a durable ledger and publish a concise tracker view.
3. Start each child from the exact accepted integration state.
4. Create a separate visible, worktree-backed task with a self-contained prompt for every implementation, experiment, integration, and final-review stage.
5. Audit each terminal handoff before changing the accepted state or starting a dependent child.
6. Preserve unrelated work and avoid duplicate tasks, branches, jobs, or experiments.

Do not use hidden subagents for work the user expects to inspect or intervene in. Keep controller-side activity read-only while a child owns an exclusive resource slot.

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

Do not combine child branches opportunistically. Create separate visible integration tasks grouped by dependency, risk, or delivery semantics. Examples include foundational changes, user-facing changes, migrations, or measured improvements.

Then create a separate final-stack task that compares the original baseline with the complete accepted result and exercises the full compatibility contract. If interactions fail, bisect accepted changes, remove offenders, update their decisions, and rerun affected validation.

Create a separate adversarial-review task when risk justifies it. Review the implementation, evidence quality, cross-change interactions, operational behavior, and hidden regressions. Resume the same review sessions for fix verification when the review tool supports it.

Publish or mark deliverables ready only when their exact heads pass required checks, combined validation succeeds, claims match evidence, and no actionable review finding remains.

## Maintain the Ledger

Keep the parent tracker and durable ledger synchronized with:

- child order, dependencies, and resource locks;
- issue, visible task, worktree, branch, commit, and PR links;
- original and current accepted states;
- status, decision, evidence location, and limitations;
- validation and review results at exact artifact versions;
- final impact table and recommended delivery order.

End with a concise report covering every child, accepted and excluded work, regressions, limitations, evidence locations, exact deliverables, and any remaining user decision.
