# Agent customizations repository

This repository is the reviewed source for the global guidance, skills, plugins, and hook registrations in `config/manifest.json`. Live Codex, Claude Code, and GitHub Copilot configuration directories are deployment targets, not editing locations.

## Working rules

- Put shared defaults in `global/shared.md`, agent-specific guidance in its overlay, each skill in `skills/<name>/`, and each agent plugin in `plugins/<target>/<name>/`. Classify changes with [customization ownership](docs/customization-ownership.md); portable skills discover repository contracts rather than embed them.
- Follow [maintenance guidance](docs/maintaining-customizations.md). Keep each skill's common path executable from `SKILL.md` alone; references hold uncommon branches and detail.
- Do not import sessions, memories, logs, artifacts, managed-job records, credentials, plugin caches, or machine-generated configuration. Keep examples portable: no usernames, home paths, repository-specific absolute paths, tokens, or session identifiers.
- Develop on an agent-owned branch or worktree. `install.ps1` activates live configuration and requires deployment authority under [Request authority](#request-authority); it is not validation. Deploy from clean `main` unless the user explicitly authorizes another source.

The manifest and installer own the managed-jobs and closing-phrase hook registrations for Codex and Claude Code and preserve unrelated machine-local entries; GitHub Copilot receives the `managed-jobs` skill without automatic lifecycle hooks, so Copilot sessions must stop started jobs explicitly and run `reconcile` after an interrupted session. Other machine-specific hooks stay outside this repository unless deliberately given a portable reviewed installer.

## Request authority

Explicit implementation commands authorize the full workflow through Ready, including commit, push, PR, cross-review, and readiness, unless the user limits the terminal state. Questions, investigation, review, and design remain read-only or proposal-only until implementation is explicitly authorized.

Installation, live deployment, release, repository administration, protection bypass, and fabricated approval are never part of delivery authority. These actions require their own explicit authority.

One standing grant: the owner's own report in the current conversation that a pull request changing manifest-deployed sources has merged authorizes one installation of current `main`. Confirm the reported merge is on fetched `origin/main`, fast-forward clean local `main` to that `origin/main` commit, install it under the [deployment guide](docs/deployment.md), and report the installed commit and the resulting `status.ps1` state. `main` holds only owner-authorized merges, so the installation covers everything merged up to that commit, not the reported pull request alone. The report grants nothing else: no other source, no safeguard override, and no discarding of live-only guidance. A merge the agent performed or only observed is not that report. If a precondition fails, report it instead of installing.

## Full delivery workflow

Use **Prepare -> Implement -> Validate -> Review -> Ready** in progress updates, with the current stage, evidence, and remaining work. Merge and deployment are separate authorized stages. This file owns repository gates; global guidance supplies defaults and skills own reusable execution.

### Prepare: establish the exact starting state

1. Confirm task scope. Before editing, read this file, `README.md`, `config/manifest.json`, and each changed skill's complete `SKILL.md` and directly required references.
2. Fetch `origin`; identify current `origin/main`. Record the remote, branch or worktree owner, HEAD, upstream, and `git status --short --branch`.
3. For instruction corrections, look for an open instruction PR for the same outcome before creating a branch. Reuse it only when this task has write ownership of its branch, no other active task is writing to it, and the clean authoring checkout matches the verified remote PR head. Add the correction as its own commit and reapply the [Ready gates](#ready-gate-and-refresh-points) to the new head.
4. Otherwise, start from verified `origin/main` in a clean agent-owned `codex/<short-task-slug>`, `claude/<short-task-slug>`, or `copilot/<short-task-slug>` branch/worktree (or, in a Copilot App worktree session, an app-prefixed `<owner>-<short-task-slug>` branch renamed with `rename_branch`).

Preserve dirty user checkouts and use an isolated worktree when unrelated changes and ownership are clear. Clarify overlapping agent work or required local inputs before writing. Never reset, stash, overwrite, or absorb unrelated work. Stop on a stale, ambiguous, or mismatched base.

### Implement, validate, and commit

- Complete the scoped change and directly affected tests/documentation. Keep one coherent problem per PR. Preserve the public/private boundary and separate changes to different skills into separate commits when practical.
- Run `pwsh ./scripts/verify.ps1` and `git diff --check` for every change before committing. Run `pwsh ./scripts/test.ps1` after changes to installation, status, verification, manifest, or other deployment tooling. Run directly affected behavioral checks under [maintenance guidance](docs/maintaining-customizations.md).
- For reviewed-versus-live drift work, use `pwsh ./scripts/status.ps1`. Drift is evidence, not installation authority.
- Record validation results, including commands that could not run, observed causes, and remaining risk. Commit intentionally and push; a local commit is intermediate. Validate is complete when applicable checks pass and are recorded.

### Pull-request identity

`kamkie` is the repository owner, reviewer, approver, and administrator, and the active GitHub CLI account opens agent-authored pull requests and performs author-side mutations for them. `GH_TOKEN` and `GITHUB_TOKEN` override the stored account, so before pull-request mutations verify that `gh api user --jq .login` returns `kamkie`. Do not switch the active account or substitute another credential. If the effective login differs or `kamkie` lacks access, stop before the mutation and report the exact blocker.

### Review: opposite-agent review and triage

Every agent-authored PR needs initial opposite-agent review before Ready.

Once the draft PR is open, verify its head and start monitoring CI and running the initial opposite-agent review on that head as separate managed jobs. Start both jobs before waiting on either. Keep the review checkout clean and its head fixed until the round ends. Triage review findings as they arrive. After a repair moves the head, monitor checks for the new head and apply the review skill's rules for later commits.

- Codex- and Copilot-authored work uses `claude-runner`, Opus, medium effort: round 1 is `/review <PR number>` from the authoring checkout. Necessary later rounds are read-only and limited to repairs since the last reviewed head. Claude-authored work gets Codex review by branch name without leaving its assigned checkout; Copilot-authored work running on a Claude model uses the same Codex branch review.
- Besides functional and safety defects in scripts, hooks, plugins, and deployment tooling, reviewers look for these repository-specific defects, each owned by the linked rule: an instruction that changes an agent decision the change did not intend, or leaves an old and a new rule contradicting ([maintenance guidance](docs/maintaining-customizations.md#maintain-agent-instructions)); a rule at the wrong owner, including a portable skill that embeds a repository contract ([customization ownership](docs/customization-ownership.md#classify-the-candidate)); private, machine-local, or generated material in a reviewed source ([Working rules](#working-rules)); a `SKILL.md` whose common path needs a reference ([skill entrypoints](docs/maintaining-customizations.md#maintain-skill-entrypoints-and-references)); or deployment tooling that changes machine-local entries the manifest does not own ([deployment scope](docs/deployment.md#scope-boundary)). A wording preference that changes no agent decision is not a finding.
- `cross-agent-review` owns triage, rejected findings, proportional re-review, post-review commit classification, and round limits. Behavior-neutral repairs may close with targeted validation and a recorded disposition; no blanket extra round. Review completes when findings and all later commits are accounted for under that skill.
- Record the result and every finding's disposition on the PR; the author posts evidence if the reviewer cannot. Repair commits credit the reviewer with `Co-Authored-By: Claude <noreply@anthropic.com>` or `Co-Authored-By: Codex <noreply@openai.com>`.
- Evidence-backed rejection counts as triage without reviewer agreement. Formal blocking reviews still gate Ready/merge; never bypass GitHub protection.

### Ready gate and refresh points

Keep one delivery record. Refresh after a push or recorded review, immediately before and after marking Ready, immediately before merge, and when new feedback, checks, ownership, or policy invalidate evidence. Fetch the remote head, thread-aware unresolved feedback, latest reviews and their SHAs, required checks, draft state, mergeability, and blocking-review state. Reuse valid evidence between these events, not a new record after every command.

Mark Ready only for the intended current remote head with passing required checks, review coverage or a repair disposition documented under `cross-agent-review`, all findings triaged, no unresolved blocking feedback or applicable `CHANGES_REQUESTED`, and clean mergeability. Reassess changes and affected evidence if the head moves; return to draft if a gate fails after Ready. Resolved feedback stays triaged, but an outstanding formal blocking review must be cleared.

Owner authorization is a merge gate, never approval invented by the author.

### Owner approval, checks, and merge

GitHub does not let `kamkie` approve a pull request it authored, so owner authorization is `kamkie`'s explicit merge instruction given for the current head. That instruction lapses when the head moves. Never fabricate approval or reuse stale authority.

When current-head owner authorization, review disposition, triage, passing required checks, non-draft state, and clean mergeability all pass, merge with `--merge --match-head-commit <sha>`. If only required checks remain pending, wait for them and then merge with the authorized SHA; do not enable auto-merge, which could merge a later head. Otherwise leave unmerged and report the exact unmet gate.

After merge, fetch `origin/main`, prove the landed result is reachable, and report that commit before global cleanup. Live deployment remains separately authorized.

### Delegated work inherits the whole workflow

Delegated prompts carry the discovered base/ownership, scope, validation, commit/push/PR authority, review disposition, Ready gates, and merge/deployment limits. Reference canonical rules; do not invent another sequence. The coordinator verifies the handoff and completes missing authorized stages. "Implement and test" alone is incomplete.
