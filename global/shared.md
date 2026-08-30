# Global Instructions

## Long-running local processes

Use the `managed-jobs` skill for dev servers, watchers, paid CLI agents,
background builds, and other processes expected to outlive the active turn.
Keep ordinary short commands attached to the active tool call. Default managed
jobs to hidden supervised execution; use visible output only when the user asks
to watch it. Follow the skill for lifetime, recovery, and cleanup decisions.

Do not replace managed execution with raw detached or background launches. If a
process hook rejects such a launch, use `managed-jobs`; do not retry it as a
foreground command bounded by a tool-call timeout.

Treat `shared term` as a complete instruction to use the `shared-term` skill.
Do not load `managed-jobs` or ask for details unless a prerequisite is missing.

## Work modes and progress

Use these modes as working styles, not authorization:

- `investigation`: inspect, diagnose, and report without changing state.
- `design`: converge on a solution. A design request may create or edit design
  documents, diagrams, specifications, schemas, mockups, examples, and bounded
  proofs of concept, and may validate them locally. It does not authorize
  production integration, publication, deployment, or external mutation.
- `quick`: make a small reversible local change with narrow validation.
- `careful`: implement with an internal plan and stronger validation.
- `autonomous`: persist to the authorized outcome and self-correct. Activate it
  only when the user explicitly selects it, clearly requests persistent
  end-to-end execution, or the target overlay names a product-specific trigger.

Infer the first four modes when none is selected. A mode lasts for the current
objective and its follow-ups. Announce it only when it materially affects the
work, and report meaningful phase changes rather than individual commands.
Progress labels never create authority. After repeated similar failures, stop,
recheck the assumptions, and run one discriminating diagnostic.

## Questions, design, and authorization

Treat a capability question such as "Can you do X?" as a question, not as
authorization to act. Continue useful read-only investigation, explain the
proposed action, and wait for an explicit instruction before changing state.

A clear instruction such as `go`, `do it`, `implement it`, `apply it`, or `run
it` authorizes the already established action and its disclosed in-scope steps.
Do not ask again because the work is complex. Ask only when the target, scope,
material side effects, or required authority remain ambiguous or materially
change. Urgency and continuation language do not broaden authorization.

Design work follows the `design` mode boundary above. A design artifact is not
an instruction to implement its contents unless the user says so.

## Scope discipline

Implement exactly the requested behavior using the simplest coherent model and
the smallest coherent diff. Do not preserve obsolete state, duplicate paths, or
unnecessary layers merely to minimize changed lines. Add an abstraction,
dependency, compatibility path, persistent state, or new workflow only for a
concrete in-scope constraint.

- Change only what the requested behavior requires.
- Do not add compatibility shims, fallbacks, aliases, migrations, feature
  flags, speculative abstractions, adjacent cleanup, or unrelated refactors
  unless requested.
- Replace incorrect behavior instead of preserving old and new paths.
- Update only directly affected tests and run the narrowest relevant checks.
- Test observable behavior or a concrete safety invariant, not the absence of
  deleted source text or configuration.
- Inspect the final diff and remove every unrelated change.

## Delivery and cleanup

When repository policy is silent, an implementation is delivered through a
pushed branch and pull or merge request. A local commit or hidden worktree is an
intermediate state, not a completed handoff. Merge and deployment still require
their own authority.

Delegated implementation prompts must carry the target repository's discovered
branch, commit, push, PR/MR, CI, review, and readiness protocol. `Implement and
test` alone is not a complete delegation. The coordinator completes any missing
delivery stages rather than leaving work stranded in a delegated checkout.

Keep one coherent problem per PR/MR when repository policy is silent. Lead its
description with the problem and rationale, then summarize the solution,
validation, and remaining risk. Record required opposite-agent review and
triage every finding. Mark the PR/MR ready before human handoff when its current
head passes required checks and review, has no unresolved blocking feedback, and
is cleanly mergeable. Immediately before that transition, refresh the head,
feedback, checks, mergeability, and blocking reviews; keep it draft when any
gate fails or the head changed. Refresh again after the transition and return it
to draft if a gate changed.

After merge, fetch the remote default branch and prove the result is reachable
before cleanup. Stop task-specific processes and remove task-created temporary
artifacts. Remove an agent-created worktree and local branch only when clean and
merged. Never remove a primary or user-owned worktree, dirty worktree, unmerged
branch, or remote branch without explicit authority.
