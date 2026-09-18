## Codex-specific workflow

For recurring Windows cleanup rejections, consult the known
[forced-deletion report](https://github.com/openai/codex/issues/45403) before
broad policy searches. In affected versions, a delete cmdlet with `-Force` can
trigger the built-in dangerous-command check and be denied under approval mode
`never`, even with Full access and no matching user rule. Check the actual
session runtime version, command shape and effective policy before applying that
diagnosis; a separate CLI on PATH or an empty user-rule match is not a substitute.
This is a diagnostic lead, not permission to bypass a rejection.

Starting or resuming a Codex Goal requests autonomous persistence for that goal.
The `Start delivery campaign <tracker>` trigger below requests autonomous
persistence for that campaign. In both cases, activation still requires the
shared autonomous-readiness gate to pass.

Before parallel agents write, give each one disjoint file or subsystem
ownership. Serialize shared files, schemas, manifests, lockfiles, migrations,
generated sources, and integration points. The coordinator inspects the
combined diff and owns integration; read-only investigation may overlap.

When an active skill or explicit output contract requires verbatim content,
output-only content, or another response shape, follow that format. It does not
change authorization, scope, safety, validation, or action boundaries.

Follow repository-required skill gates; do not infer new approval gates from
optional advice.

Correct an agent-introduced mistake without asking when the correction is
local, reversible, unambiguous, safe for user work, and within the existing
authorization, and disclose it. For external changes or credential use, first
check that the exact action, target, purpose, and effects are covered by the
existing authorization and applicable target rules; continue if they are, and
ask only for a material scope expansion or missing authority. Do not rewrite
shared history, destroy user work, or bypass a restriction.

`Start delivery campaign <tracker>` authorizes the bounded campaign inventory,
visible task/worktree/branch creation, local commits, remote branch pushes,
draft pull or merge requests, tracker links and status updates, CI monitoring,
required opposite-agent review with finding fixes and re-review, and each
repository-gated readiness transition. Use the `orchestrate-work-campaigns`
workflow and discover each repository's delivery rules at runtime. This trigger
does not authorize merge or deployment.
