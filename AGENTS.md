# Agent customizations repository

This repository is the reviewed source for the global guidance, skills, and hook
registrations in `config/manifest.json`. Live Codex and Claude Code configuration
directories are deployment targets, not editing locations.

## Working rules

- Put shared defaults in `global/shared.md`, agent-specific guidance in its
  overlay, and each skill in `skills/<name>/`. Classify changes with
  [customization ownership](docs/customization-ownership.md); portable skills
  discover repository contracts rather than embed them.
- Follow [maintenance guidance](docs/maintaining-customizations.md). Keep each
  skill's common path executable from `SKILL.md` alone; references hold uncommon
  branches and detail.
- Do not import sessions, memories, logs, artifacts, managed-job records,
  credentials, plugin caches, or machine-generated configuration. Keep examples
  portable: no usernames, home paths, repository-specific absolute paths, tokens,
  or session identifiers.
- Develop on an agent-owned branch or worktree. `install.ps1` activates live
  configuration and requires explicit deployment authority; it is not validation.
  Deploy from clean `main` unless the user explicitly authorizes another source.

The manifest and installer own managed-jobs hook registrations for both agents
and preserve unrelated machine-local entries. Other machine-specific hooks stay
outside this repository unless deliberately given a portable reviewed installer.

## Request authority

Explicit implementation commands authorize the full workflow through Ready,
including commit, push, PR, cross-review, and readiness, unless the user limits
the terminal state. Questions, investigation, review, and design remain read-only
or proposal-only until implementation is explicitly authorized.

Installation, live deployment, release, repository administration,
protection bypass, and fabricated approval are never part of delivery authority.
These actions require their own explicit authority.

## Full delivery workflow

Use **Prepare -> Implement -> Validate -> Review -> Ready** in progress updates,
with the current stage, evidence, and remaining work. Merge and deployment are
separate authorized stages. This file owns repository gates; global guidance
supplies defaults and skills own reusable execution.

### Prepare: establish the exact starting state

1. Confirm task scope. Before editing, read this file, `README.md`,
   `config/manifest.json`, and each changed skill's complete `SKILL.md` and
   directly required references.
2. Fetch `origin`; identify current `origin/main`. Record the remote, branch or
   worktree owner, HEAD, upstream, and `git status --short --branch`.
3. Start from that verified base in a clean agent-owned `codex/<short-task-slug>`
   or `claude/<short-task-slug>` branch/worktree. Preserve dirty user checkouts;
   use an isolated worktree when unrelated changes and ownership are clear.
   Clarify overlapping agent work or required local inputs before writing.
   Never reset, stash, overwrite, or absorb unrelated work. Stop on a stale,
   ambiguous, or mismatched base.

### Implement, validate, and commit

- Complete the scoped change and directly affected tests/documentation. Keep one
  coherent problem per PR, preserve the public/private boundary, and separate
  changes to different skills into separate commits when practical.
- Run `pwsh ./scripts/verify.ps1` and `git diff --check` for every change before
  committing. Run `pwsh ./scripts/test.ps1` after changes to installation, status,
  verification, manifest, or other deployment tooling. Run directly affected
  behavioral checks under [maintenance guidance](docs/maintaining-customizations.md).
- For reviewed-versus-live drift work, use `pwsh ./scripts/status.ps1`. Drift
  is evidence, not installation authority.
- Record validation results, including commands that could not run, observed
  causes, and remaining risk. Commit intentionally and push; a local commit is
  intermediate. Validate is complete when applicable checks pass and are recorded.

### Use the bot for author-side pull-request mutations

`kamkie` is the repository owner, reviewer, approver, and administrator.
`kamkie-codex-bot` opens Codex-authored pull requests and performs author-side
mutations for them. Commits and pushes may use the configured Git or SSH
credentials because pull-request authorship is determined by the credential
that creates the pull request.

For pull-request creation and later author-side mutations, obtain the bot token
for the individual command, verify the effective login, and remove it
immediately:

```powershell
$botToken = gh auth token --hostname github.com --user kamkie-codex-bot
$previousToken = $env:GH_TOKEN
try {
    $env:GH_TOKEN = $botToken
    if ((gh api user --jq .login) -ne 'kamkie-codex-bot') {
        throw 'Expected the kamkie-codex-bot GitHub identity.'
    }
    gh pr create --draft # supply the task-specific base, head, title, and body
} finally {
    if ($null -eq $previousToken) {
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
    } else {
        $env:GH_TOKEN = $previousToken
    }
    $botToken = $null
}
```

Do not globally switch the active GitHub account, print or persist the token, or
open a Codex-authored pull request as `kamkie`. If the bot credential is
unavailable or lacks access, stop before the mutation and report the exact
blocker.

### Review: opposite-agent review and triage

Every agent-authored PR needs initial opposite-agent review before Ready.

- Codex-authored work uses `claude-runner`, Opus, medium effort: round 1 is
  `/review <PR number>` from the authoring checkout. Necessary later rounds are
  read-only and limited to repairs since the last reviewed head. Claude-authored
  work gets Codex review by branch name without leaving its assigned checkout.
- `cross-agent-review` owns triage, rejected findings, proportional re-review,
  post-review commit classification, and round limits. Behavior-neutral repairs
  may close with targeted validation and a recorded disposition; no blanket
  extra round. Review completes when findings and all later commits are accounted
  for under that skill.
- Record the result and every finding's disposition on the PR; the author posts
  evidence if the reviewer cannot. Repair commits credit the reviewer with
  `Co-Authored-By: Claude <noreply@anthropic.com>` or
  `Co-Authored-By: Codex <noreply@openai.com>`.
- Evidence-backed rejection counts as triage without reviewer agreement. Formal
  blocking reviews still gate Ready/merge; never bypass GitHub protection.

### Ready gate and refresh points

Keep one delivery record. Refresh after a push or recorded review, immediately
before and after marking Ready, immediately before merge/auto-merge, and when new
feedback, checks, ownership, or policy invalidate evidence. Fetch the remote head,
thread-aware unresolved feedback, latest reviews and their SHAs, required checks,
draft state, mergeability, and blocking-review state. Reuse valid evidence between
these events, not a new record after every command.

Mark Ready only for the intended current remote head with passing required checks,
review coverage or a documented behavior-neutral repair disposition, all findings
triaged, no unresolved blocking feedback or applicable `CHANGES_REQUESTED`, and
clean mergeability. Reassess changes and affected evidence if the head moves;
return to draft if a gate fails after Ready. Resolved feedback stays triaged,
but an outstanding formal blocking review must be cleared.

CODEOWNERS requests `kamkie` for bot-authored pull requests. Owner authorization
is a merge gate, never approval invented by the author.

### Owner approval, checks, and merge

Require the latest `kamkie` approval to apply to the current head. Never
fabricate approval or reuse stale authority.

When current-head owner authorization, review disposition, triage, passing required
checks, non-draft state, and clean mergeability all pass, merge as
`kamkie-codex-bot` with `--merge --match-head-commit <sha>`. If only required
checks remain pending, enable guarded auto-merge with those flags. Otherwise
leave unmerged and report the exact unmet gate.

After merge, fetch `origin/main`, prove the landed result is reachable, and report
that commit before global cleanup. Live deployment remains separately authorized.

### Delegated work inherits the whole workflow

Delegated prompts carry the discovered base/ownership, scope, validation,
commit/push/PR authority, review disposition, Ready gates, and merge/deployment
limits. Reference canonical rules; do not invent another sequence. The coordinator
verifies the handoff and completes missing authorized stages. "Implement and test"
alone is incomplete.
