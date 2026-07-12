# Agent customizations repository

This repository is the reviewed source of truth for the global agent guidance
and custom skills listed in `config/manifest.json`. The live Codex and Claude
Code configuration directories are deployment targets, not editing locations.

## Working rules

- Keep target-specific global guidance in `global/` and each skill inside its
  own `skills/<name>/` directory.
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

Machine-specific hook registration remains outside this repository unless a
portable, reviewable installation mechanism is added deliberately.

## Request authority

- A direct instruction to implement, apply, fix, or otherwise make a repository
  change authorizes the complete delivery workflow below unless the user limits
  the requested terminal state. The user does not need to repeat commit, push,
  pull-request, cross-review, or readiness steps.
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

### Open the draft pull request as the bot

`kamkie` is the repository owner, reviewer, approver, and administrator.
`kamkie-codex-bot` opens Codex-authored pull requests and performs author-side
mutations for them. Commits and pushes may continue to use the configured Git/SSH
credentials because PR authorship is determined by the credential that creates
the PR.

For PR creation and later author-side mutations, obtain the bot token for the
individual command, verify the effective login, and remove it immediately:

```powershell
$env:GH_TOKEN = gh auth token --hostname github.com --user kamkie-codex-bot
try {
    if ((gh api user --jq .login) -ne 'kamkie-codex-bot') {
        throw 'Expected the kamkie-codex-bot GitHub identity.'
    }
    gh pr create --draft # supply the task-specific base, head, title, and body
} finally {
    Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
}
```

Do not globally switch the active GitHub account, print or persist the token, or
open a Codex-authored PR as `kamkie`. If the bot credential is unavailable or
does not have access, stop before PR creation and report the exact blocker.

### Cross-review before human handoff

- Every agent-authored PR receives opposite-agent review before it is marked
  ready. A Codex-authored PR uses the `claude-runner` skill with the Opus reviewer
  at medium effort and `/review <PR number>` from the authoring checkout. A
  Claude-authored PR receives Codex review by branch name without moving the work
  out of its assigned checkout.
- Ensure the review result is recorded on the PR. If the reviewer returns
  findings without posting them, add a concise PR comment naming the reviewer,
  findings, and triage decision.
- Triage every finding: fix it or answer it on the PR. Commits that implement a
  review finding credit the reviewer with `Co-Authored-By: Claude
  <noreply@anthropic.com>` or `Co-Authored-By: Codex <noreply@openai.com>`.
- Re-run affected validation after fixes. Mark the PR ready only after the review
  is recorded and all findings are triaged. CODEOWNERS then requests `kamkie` as
  the human owner reviewer.

### Owner approval, checks, and merge

After a review is recorded, a commit is pushed, or the PR is marked ready,
re-fetch the PR's head SHA, latest reviews, required checks, draft state,
mergeability, and blocking-review state.

- Owner approval is valid only when the latest `kamkie` approval applies to the
  current head SHA. Never manufacture approval with a stored owner credential or
  reuse approval from an earlier commit.
- When current-head owner approval exists and cross-review, triage, required
  checks, non-draft state, and clean mergeability all pass, merge immediately as
  `kamkie-codex-bot` with the repository's merge-commit method and
  `--match-head-commit <sha>`.
- If every other gate passes but required checks are still pending, enable
  guarded auto-merge with `--merge --match-head-commit <sha>` instead of bypassing
  protection.
- If approval is absent, a check failed, the head changed, the PR is draft, the
  merge is not clean, or a blocking review exists, leave the PR unmerged and
  report that exact state.
- After merge, fetch `origin/main`, prove the PR result is reachable from it, and
  report the landed commit. Do not claim completion from a stale local ref.

### Delegated work inherits the whole workflow

Prompts for background tasks, visible Codex tasks, subagents, or other agent CLIs
must include this full terminal contract. "Implement and test" is not a complete
delegation. A branch task is unfinished until its branch is pushed, its draft PR
exists, cross-review is recorded, findings are triaged, and its exact ready,
blocked, auto-merge, or merged state is verified. When a delegated task stops
short, the coordinating agent completes the missing handoff steps instead of
asking the user to repeat them.
