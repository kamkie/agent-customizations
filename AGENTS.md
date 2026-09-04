# Agent customizations repository

This repository is the reviewed source of truth for the global agent guidance
and custom skills listed in `config/manifest.json`. The live Codex and Claude
Code configuration directories are deployment targets, not editing locations.

## Working rules

- Keep shared global guidance in `global/shared.md`, target-specific guidance in
  the matching overlay, and each skill inside its own `skills/<name>/` directory.
- Classify new guidance using [`docs/customization-ownership.md`](docs/customization-ownership.md)
  before adding it. Reusable skills own repeated workflows and discover
  repository policy; they do not embed repository-specific contracts.
- Follow [`docs/maintaining-customizations.md`](docs/maintaining-customizations.md)
  when changing agent instructions or skills. Keep each skill's common path
  executable from `SKILL.md` alone; use references for uncommon branches and
  details, not to complete the normal workflow.
- Do not import sessions, memories, logs, artifacts, managed-job records,
  credentials, plugin caches, or machine-generated configuration.
- Keep examples portable. Do not commit usernames, home-directory paths,
  repository-specific absolute paths, tokens, or session identifiers.
- Treat changes to different skills as separate commits when practical.
- Run `pwsh ./scripts/verify.ps1` before committing.
- Run `pwsh ./scripts/test.ps1` after changing deployment tooling.
- Use `pwsh ./scripts/status.ps1` to compare reviewed source with live agent
  installations.
- Do not run `install.ps1` unless deployment to the live agent installation is
  explicitly authorized. Installation is an activation step, not validation.
- Develop changes on a branch or worktree. Deploy from a clean `main` checkout
  unless the user explicitly authorizes another source.

The manifest and installer own the reviewed Codex and Claude Code managed-jobs
hook registrations and preserve unrelated entries in each machine-local hook
file. Other machine-specific hook registration remains outside this repository
unless a portable, reviewable installation mechanism is added deliberately.

## Request authority

- A direct instruction to implement, apply, fix, or otherwise make a repository
  change authorizes the complete delivery workflow below unless the user limits
  the requested terminal state. The user does not need to repeat commit, push,
  pull-request, cross-review, or readiness steps.
- While the [temporary bot-unavailable rule](docs/temporary-bot-unavailable.md)
  is active, a pull request
  authored by `kamkie` requires a new explicit `merge PR <number> at <sha>`
  instruction after readiness. General implementation authority stops at the
  ready pull request because GitHub cannot record owner approval on a
  self-authored pull request.
- A question, investigation, review, or design request remains read-only or
  proposal-only until implementation is explicitly authorized.
- Repository delivery authority never includes `install.ps1`, deployment to a
  live agent home, release, repository administration, bypassing protection, or
  fabricating owner approval. Those actions require their own explicit authority.

## Full delivery workflow

Use **Prepare -> Implement -> Validate -> Review -> Ready** in progress updates.
Show the current stage, its evidence, and what remains. Merge and deployment are
separate authorized stages. This section owns this repository's delivery gates;
global guidance supplies defaults and skills supply reusable execution steps.

| Stage | Complete when |
| --- | --- |
| Prepare | The current base, task ownership, scope, and isolated branch or worktree are verified. |
| Implement | The scoped change and directly affected tests or documentation are complete. |
| Validate | The applicable commands below pass and their results are recorded. |
| Review | Opposite-agent review is recorded; findings and any later commits have a disposition under the review skill. |
| Ready | The single readiness gate below passes for the current remote head. |

### Prepare: establish the exact starting state

1. Read this file, `README.md`, `config/manifest.json`, and every changed
   skill's complete `SKILL.md` plus directly required references before editing.
2. Fetch `origin` and identify exact current `origin/main`. Record the remote,
   branch or worktree owner, HEAD, upstream, and `git status --short --branch`.
3. Start implementation from that base in a clean agent-owned
   `codex/<short-task-slug>` or `claude/<short-task-slug>` branch or worktree.
   A dirty user checkout is not the implementation base: preserve it and use an
   isolated clean worktree when its changes are unrelated and ownership is clear.
   If another agent or local changes create uncertain overlap or required inputs,
   ask how to coordinate before writing. Do not reset, stash, overwrite, or
   absorb unrelated work. Stop on a stale, ambiguous, or mismatched task base.

### Implement, validate, and commit

- Keep one coherent problem in the PR, preserve the public/private boundary, and
  keep changes to different skills in separate commits when practical.
- Run `pwsh ./scripts/verify.ps1` and `git diff --check` for every change.
- Run `pwsh ./scripts/test.ps1` after changing installation, status,
  verification, manifest, or other deployment tooling. Run directly affected
  behavioral checks as described in `docs/maintaining-customizations.md`.
- Use `pwsh ./scripts/status.ps1` for reviewed-versus-live drift work. Drift is
  evidence, not permission to install.
- Commit intentionally and push. Report any validation that could not run, its
  observed cause, and the remaining risk. A local commit is intermediate.

### Apply the temporary pull-request policy when active

The [temporary bot-unavailable policy](docs/temporary-bot-unavailable.md) is
active until this notice is removed.

Immediately before PR creation or another author-side mutation, read that policy
and its active notice. It alone owns the current GitHub actor, credential
boundary, draft creation, and owner-authored exact-head authorization rule.
Do not load it before reaching an author-side mutation.

### Review: opposite-agent review and triage

Every agent-authored PR receives an initial opposite-agent review before Ready.

- For Codex-authored work, use `claude-runner` with Opus at medium effort.
  Round 1 uses `/review <PR number>` from the authoring checkout. Necessary later
  rounds use a read-only prompt restricted to the repair range since the last
  reviewed head. Claude-authored work receives Codex review by branch name
  without leaving its assigned checkout.
- The `cross-agent-review` skill is the canonical owner of finding triage,
  proportional re-review, rejected findings, post-review commit classification,
  and round limits. A behavior-neutral repair may close with targeted validation
  and a recorded disposition under that rule; do not add a blanket extra round.
- Record the review result and each finding's disposition on the PR. When the
  reviewer cannot post, the author posts the evidence. Finding repairs credit
  `Co-Authored-By: Claude <noreply@anthropic.com>` or
  `Co-Authored-By: Codex <noreply@openai.com>`.
- A rejected finding with evidence is triaged; it does not require reviewer
  agreement. Formal blocking reviews remain subject to the Ready/merge gates.
  Repository policy does not permit bypassing GitHub protection.

### Ready gate and refresh points

Keep one delivery record. At each refresh below, fetch the remote head,
thread-aware unresolved feedback, latest reviews and their commit SHAs, required
checks, draft state, mergeability, and blocking-review state. Reuse an unchanged
record between these events; do not reread it after every local command.

Refresh after a push or a recorded review, immediately before and after marking
Ready, and immediately before merge or enabling auto-merge. Also refresh when
new feedback, check results, ownership, or policy changes invalidate evidence.

Mark Ready only when the intended current remote head has passing required
checks, review coverage or a documented behavior-neutral repair disposition,
all findings triaged, no unresolved blocking feedback or applicable
`CHANGES_REQUESTED`, and clean mergeability. If the head moves, reassess its
changes and refresh affected evidence before proceeding. If a gate changes
after Ready, return the PR to draft. Earlier resolved feedback is not untriaged
work; an outstanding formal blocking review still prevents merge until cleared.

For non-owner-authored PRs, CODEOWNERS requests `kamkie` as human reviewer.
Owner-authored PRs use the temporary policy's exact-head authorization rule.
Owner authorization is a merge gate, not permission invented by the author.

### Owner approval, checks, and merge

Use the same refreshed delivery record. Apply the active owner-authorization
rule from the temporary policy, or otherwise require the latest owner approval
at the current head. Never manufacture approval or reuse stale authorization.

When current-head owner authorization, review disposition, triage, passing
required checks, non-draft state, and clean mergeability all pass, merge as
`kamkie` with the merge-commit method and `--match-head-commit <sha>`.
If only required checks are still pending and all other gates pass, enable
guarded auto-merge with `--merge --match-head-commit <sha>`. Otherwise leave the
PR unmerged and report the exact unmet gate.

After merge, fetch `origin/main`, prove the landed result is reachable from it,
and report that commit before applying the global cleanup rules. Deployment to
live agent homes remains a separate explicitly authorized activation.

### Delegated work inherits the whole workflow

Prompts for delegated repository work must carry the discovered target contract:
base and ownership, scope, validation, commit/push/PR authority, review
disposition, Ready gates, and merge/deployment limits. Reference canonical rules
instead of inventing another delivery sequence. The coordinator verifies the
handoff and completes missing authorized stages; `implement and test` alone is
not a complete delivery contract.
