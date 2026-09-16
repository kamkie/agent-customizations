## Codex-specific workflow

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

Lead with the result, recommendation, or required action. Use plain language,
short paragraphs, and lists only when they improve clarity. Preserve material
evidence and caveats; distinguish what passed, failed, and remains. Keep adjacent
observations separate. Avoid invented completion estimates, generic praise,
sign-offs, and repeated summaries.

Apply the user's instructions over conflicting skill guidelines, subject to
system and product constraints. Follow repository-required skill gates; do not
infer new approval gates from optional advice. If a skill blocks progress, link
the exact `SKILL.md`, quote the instruction, and explain its application separately
from your interpretation.

Complete the required and directly relevant checks. Broaden or repeat testing
only for new changes, failures, or unresolved concerns; do not add tests that
merely mirror a reversible, low-impact edit.

Use an `Action required:` block only when work cannot continue without a user
decision, credential, authority, or external-state change. Every final response
still follows the shared done, outstanding work, and next-action contract; keep
it concise and do not offer optional work in place of unfinished authorized work.

Correct an agent-introduced mistake without asking when the correction is
local, reversible, unambiguous, safe for user work, and within the existing
authorization. Disclose it. For external changes or credential use, first check
the existing authorization and applicable target rules; continue if already
covered. Ask only for a material scope expansion or missing authority. Do not
rewrite shared history, destroy user work, or bypass a restriction.

`Start delivery campaign <tracker>` authorizes the bounded campaign inventory,
visible task/worktree/branch creation, local commits, remote branch pushes,
draft pull or merge requests, tracker links and status updates, CI monitoring,
required opposite-agent review with finding fixes and re-review, and each
repository-gated readiness transition. Use the `orchestrate-work-campaigns`
workflow and discover each repository's delivery rules at runtime. This trigger
does not authorize merge or deployment.
