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

### Establish the exact starting state

1. Read this file, `README.md`, `config/manifest.json`, and every changed skill's
   complete `SKILL.md` plus directly required references before editing.
2. Fetch `origin` and prove that the intended base is the exact current
   `origin/main`. Record the remote, branch or worktree owner, HEAD, upstream, and
   `git status --short --branch`.
3. Start from a clean agent-owned `codex/<short-task-slug>` or
   `claude/<short-task-slug>` branch or worktree. Do not reset, stash, overwrite,
   or absorb unrelated user work to manufacture a clean state. Stop on a dirty,
   stale, ambiguous, or mismatched base.

### Implement, validate, and commit

- Keep the diff scoped to the authorized task. Preserve the public/private
  boundary and keep changes to different skills in separate commits when
  practical.
- Run `pwsh ./scripts/verify.ps1` and `git diff --check` for every change.
- Run `pwsh ./scripts/test.ps1` after changing installation, status,
  verification, manifest, or other deployment tooling.
- Use `pwsh ./scripts/status.ps1` when the task concerns reviewed-versus-live
  drift. A nonzero drift result is evidence, not permission to install.
- Commit intentionally on the agent-owned branch and push it. Report every
  validation command that could not run, why, and the remaining risk.

### Apply the temporary pull-request policy when active

The [temporary bot-unavailable policy](docs/temporary-bot-unavailable.md) is
active until this notice is removed.

Immediately before pull-request creation or another author-side mutation, read
the complete [temporary bot-unavailable policy](docs/temporary-bot-unavailable.md).
It owns the current GitHub actor, credential boundary, draft creation rule, and
owner-authored exact-head authorization gate. Do not load it for work that has
not reached an author-side mutation.

### Cross-review before human handoff

- Every agent-authored PR receives opposite-agent review before it is marked
  ready. A Codex-authored PR uses the `claude-runner` skill with the Opus reviewer
  at medium effort: round 1 uses `/review <PR number>` from the authoring
  checkout, and each later round uses a read-only prompt restricted to the exact
  repair range from the previously reviewed head to the current head. A
  Claude-authored PR receives Codex review by branch name without moving the work
  out of its assigned checkout.
- The `cross-agent-review` skill owns the executable loop for that review:
  commit-before-review, per-finding triage, credited fix commits, and the bounded
  round decision. This section stays authoritative for who reviews whom and for
  the readiness and merge gates below.
- Ensure the review result is recorded on the PR. If the reviewer returns
  findings without posting them, add a concise PR comment naming the reviewer,
  findings, and triage decision.
- In a later round, reject a new finding outside the repair range unless the
  reviewer identifies the changed line in that range that causes it. A reviewer
  run that substantially ignores the range is invalid and does not consume a
  round.
- Triage every finding: fix it or answer it on the PR. Commits that implement a
  review finding credit the reviewer with `Co-Authored-By: Claude
  <noreply@anthropic.com>` or `Co-Authored-By: Codex <noreply@openai.com>`.
- Before marking ready, re-fetch the head and review threads. Keep the PR draft
  if the head changed, a finding is untriaged, or `CHANGES_REQUESTED` applies to
  the current head. Re-fetch after the transition and revert to draft if this
  gate changed.
- Resolved feedback on an earlier head does not block readiness, but its review
  remains a merge blocker until current-head approval. For pull requests not
  authored by `kamkie`, CODEOWNERS then requests `kamkie` as the human owner
  reviewer. A temporary owner-authored pull request follows the exact-head
  authorization rule below instead.

### Owner approval, checks, and merge

After a review is recorded, a commit is pushed, or the PR is marked ready,
re-fetch the PR's head SHA, thread-aware unresolved feedback, latest reviews,
required checks, draft state, mergeability, and blocking-review state.

- Apply the active owner-authorization rule. While the temporary bot-unavailable
  policy is active, use its exact current-head gate; otherwise require the latest
  owner approval to apply to the current head. Never manufacture or reuse stale
  approval.
- When applicable current-head owner authorization exists and cross-review,
  triage, required checks, non-draft state, and clean mergeability all pass,
  merge immediately as `kamkie` with the repository's merge-commit method and
  `--match-head-commit <sha>`.
- If every other gate passes but required checks are still pending and
  applicable current-head owner authorization exists, enable guarded auto-merge
  with `--merge --match-head-commit <sha>` instead of bypassing protection.
- If approval or exact-head authorization is absent, a check failed, the head
  changed, the PR is draft, the merge is not clean, or a blocking review
  exists, leave the PR unmerged and report that exact state.
- After merge, fetch `origin/main`, prove the PR result is reachable from it, and
  report the landed commit. Do not claim completion from a stale local ref.

### Delegated work inherits the whole workflow

Prompts for background tasks, visible Codex tasks, subagents, or other agent CLIs
must include this full terminal contract. For another repository, discover and
inject its exact branch, commit, push, PR/MR, CI, review, readiness, merge, and
deployment rules. "Implement and test" is not a complete delegation. A local
commit or hidden worktree is intermediate state, not delivery. A branch task is
unfinished until its branch is pushed, its draft PR exists, cross-review is
recorded, findings are triaged, and its exact ready, blocked, auto-merge, or
merged state is verified. When delegated work stops short, the coordinator
completes the missing handoff instead of asking the user to repeat authority.
