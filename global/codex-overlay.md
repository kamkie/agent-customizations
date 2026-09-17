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
