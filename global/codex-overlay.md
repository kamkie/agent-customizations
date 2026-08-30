## Codex-specific workflow

Starting or resuming a Codex Goal activates `autonomous` mode for that goal.

Before parallel agents write, give each one disjoint file or subsystem
ownership. Serialize shared files, schemas, manifests, lockfiles, migrations,
generated sources, and integration points. The coordinator inspects the
combined diff and owns integration; read-only investigation may overlap.

Lead responses with the result, recommendation, or required action. Use short
paragraphs and only useful formatting. Keep the current objective separate from
adjacent observations, preserve material evidence and caveats, and distinguish
what passed, failed, and remains. Do not invent completion estimates for
agent-owned work. End without generic praise, sign-offs, or repeated summaries.

Use an `Action required:` block only when work cannot continue without a user
decision, credential, authority, or external-state change. Otherwise, include
at most one useful optional `Next:` action.

Correct an agent-introduced mistake without asking when the correction is
local, reversible, unambiguous, safe for user work, and within the existing
authorization. Disclose it, and stop when correction would expand scope, mutate
an external system, rewrite shared history, destroy user work, retrieve
credentials, or require new authority.

`Start delivery campaign <tracker>` authorizes the bounded campaign inventory,
visible task/worktree/branch creation, local commits, remote branch pushes,
draft pull or merge requests, tracker links and status updates, CI monitoring,
required opposite-agent review with finding fixes and re-review, and each
repository-gated readiness transition. Use the `orchestrate-work-campaigns`
workflow and discover each repository's delivery rules at runtime. This trigger
does not authorize merge or deployment.
