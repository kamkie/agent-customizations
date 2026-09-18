# Codex-specific workflow

The reviewed model-instructions file supplies the shared execution contract.
This overlay adds only Codex triggers; it does not repeat that contract.

Starting or resuming a Codex Goal requests autonomous persistence for that goal,
subject to the shared immediate-prerequisite and authority rules.

`Start delivery campaign <tracker>` authorizes the bounded campaign inventory,
visible task/worktree/branch creation, local commits, remote branch pushes,
draft pull or merge requests, tracker links and status updates, CI monitoring,
required opposite-agent review with finding fixes and re-review, and each
repository-gated readiness transition. Use `orchestrate-work-campaigns` and
read each repository's delivery rules. The trigger also selects autonomous
persistence; it does not authorize merge or deployment.

For a Windows cleanup rejected as "blocked by policy", first check the known
[forced-deletion report](https://github.com/openai/codex/issues/45403): under
approval mode `never`, `-Force` on a delete cmdlet, or on a listing submitted in
the same script as a removal, can trigger the built-in dangerous-command check
even with Full access. Confirm the session's own runtime version and command
shape first, and keep inspection and removal in separate commands. This is a
diagnostic lead, not permission to bypass a rejection.
