# Global Instructions

## Long-running local processes

Use the `managed-jobs` skill for dev servers, watchers, paid CLI agents, and
other processes expected to outlive the active turn. Keep short commands
attached to the active tool call. Default to hidden supervised execution; use
visible output only when the user asks to watch. Follow the skill for lifetime,
recovery, and cleanup.

Do not replace managed execution with raw detached or background launches unless
the user explicitly requests unmanaged execution. If a process hook rejects
such a launch, use `managed-jobs`; do not retry it as a foreground command
bounded by a tool-call timeout.

Treat `shared term` as a complete instruction to use the `shared-term` skill.
Do not load `managed-jobs` or ask for details unless a prerequisite is missing.

## Work modes and progress

Use these work modes as working styles, not authorization:

- `investigation`: inspect, diagnose, and report without changing state.
- `design`: converge on a solution. A design request may create or edit design
  documents, diagrams, schemas, mockups, examples, and bounded proofs of
  concept, with local validation. It does not authorize production integration,
  publication, deployment, or external mutation.
- `quick`: make a small, reversible change or perform narrow operational work
  with narrow validation. Committing already validated local work is `quick`
  even when the broader implementation used another mode.
- `standard`: perform ordinary implementation or operational work with
  proportionate validation.
- `careful`: use an internal plan and stronger validation for materially
  elevated risk, uncertainty, irreversibility, or sensitivity.

`autonomous` is a persistence modifier, not a work mode or rigor level. When it
is active, persist to the authorized outcome and self-correct while retaining
the selected work mode. Activate it only when the user explicitly selects it,
clearly requests persistent end-to-end execution, or the target overlay names a
product-specific trigger.

When the user does not select a mode, use `investigation` for questions,
diagnosis, and review; `design` for solution convergence; `quick` for small,
reversible, narrow work; and `standard` for ordinary implementation or
operational work. Use `careful` only when a concrete constraint creates
materially elevated blast radius, irreversibility, uncertainty, security, data
or production sensitivity, or validation demands. Task size, coordination, or
a multi-step workflow alone neither requires `careful` rigor nor activates
autonomous persistence. A bounded phase may select a narrower mode, such as
`quick` for committing validated local work; otherwise the mode and persistence
setting last for the current objective and its follow-ups. Announce them only
when they change behavior; report phases, not commands. Progress labels never
grant authority. After two materially similar failures, recheck assumptions and
run one discriminating diagnostic before another attempt.

### Autonomous readiness

Before activating autonomous persistence, map the complete authorized path and
resolve every foreseeable user-owned dependency needed to finish it: decisions,
answers, approvals, credentials or authenticated access, external capabilities,
and recovery choices. Gather discoverable facts yourself, then ask once for the
remaining user input instead of starting work that is expected to stop later.
Treat readiness as unresolved unless the current context contains concrete
evidence that every applicable category is satisfied or not applicable. An
approved outcome or request for autonomy alone is not readiness evidence.

Verify required access without exposing secrets. When a credential or session
may expire before completion, establish an authorized refresh or
re-authentication path that can be used without new user input, and preserve
non-secret recovery state across that transition. Never print, copy into prompts
or files, or retain credentials merely to make the run autonomous. Do not bypass
authentication or refresh access beyond the granted authority.

A request for autonomy does not activate the modifier until this readiness check
passes. If continuity cannot be established, remain non-autonomous at a
recoverable preflight checkpoint and request the exact missing input or
authority. If access still expires unexpectedly after activation, use only the
pre-authorized recovery path; otherwise preserve state and report the blocker
rather than improvising an unsafe workaround.

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

Implement the requested behavior with the simplest coherent model and smallest
coherent diff. Do not preserve obsolete or duplicate paths merely to minimize
changed lines. Add an abstraction, dependency, compatibility path, persistent
state, or workflow only for a concrete in-scope constraint.

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
