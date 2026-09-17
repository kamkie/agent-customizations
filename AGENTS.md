# Agent customizations repository

This is the reviewed source for the guidance, skills and hook registrations in
`config/manifest.json`. Live agent homes are deployment targets, not editing
locations. Shared behavior belongs in `global/shared.md`; target fragments add
only agent-specific behavior. The manifest renders shared policy once per agent.

## Working rules

- Classify changes with [customization ownership](docs/customization-ownership.md).
  Portable skills discover repository contracts rather than embed them.
- Follow [maintenance guidance](docs/maintaining-customizations.md). Keep each
  skill's normal path executable from `SKILL.md`; references hold exceptions.
- Keep sessions, memories, logs, runtime records, credentials, plugin caches and
  machine-generated configuration out of this repository. Examples must be
  portable, without usernames, home paths, private endpoints or session IDs.
- Develop in a clean agent-owned branch/worktree. `install.ps1` activates live
  configuration and requires explicit deployment authority; it is not validation.
  Deploy from clean `main` unless the user explicitly authorizes another source.

The manifest/installer own managed-job hook registrations for both agents and
preserve unrelated machine-local entries. Other machine-specific hooks remain
outside this repository without a deliberately reviewed portable installer.

## Request authority

Explicit implementation commands authorize this workflow through Ready:
commit, push, draft PR, cross-review, finding repair and readiness, unless the
user limits the terminal state. Questions, investigation, review and design do
not authorize implementation. Merge, live installation, release, administration
and protection changes require separate authority; never fabricate approval.

Use **Prepare -> Implement -> Validate -> Review -> Ready** for meaningful
transitions. Track authorized merge/deployment separately. Global guidance owns
general execution behavior; this file owns the repository gates below.

## Full delivery workflow

### Prepare: establish the exact starting state

1. Read this file, `README.md`, `config/manifest.json`, and the complete changed
   skill entrypoints and directly required references before editing.
2. Fetch `origin`; record `origin/main`, remote, current HEAD/upstream, branch or
   worktree ownership and `git status --short --branch`.
3. Start from that verified base in a clean `codex/<slug>` or `claude/<slug>`
   branch/worktree. For an explicitly requested stack, use the verified parent
   PR head and target its branch. Preserve unrelated changes and clarify actual
   overlap. Never reset, stash, overwrite, absorb or silently substitute a base.

### Implement, validate, and commit

Keep one coherent problem per PR and separate different skills into commits
when practical. Include directly affected tests/docs and preserve the
public/private boundary.

| Change | Required validation |
| --- | --- |
| Every change | `pwsh ./scripts/verify.ps1` and `git diff --check` before commit |
| Installer, status, verifier, manifest or deployment tooling | `pwsh ./scripts/test.ps1` |
| Instruction/skill behavior | Directly affected checks under [maintenance guidance](docs/maintaining-customizations.md) |
| Reviewed-versus-live comparison | `pwsh ./scripts/status.ps1`; inspection grants no installation authority |

Record exact results and limitations, including checks that could not run.
Inspect the final diff, commit intentionally and push. Validate is complete
when applicable checks pass and their evidence is recorded; a local commit is
intermediate. Reuse valid evidence rather than rerunning unchanged work.

### Apply the temporary pull-request policy when active

The [temporary bot-unavailable policy](docs/temporary-bot-unavailable.md) is
active until this notice is removed.

Read that policy and this notice immediately before PR creation or any author-side
mutation, never earlier. The policy owns the actor, credential boundary, draft
creation, and owner-authored exact-head authorization rule.

### Review: opposite-agent review and triage

Every agent-authored PR requires initial opposite-agent review. Codex-authored
work uses `claude-runner`, Opus, medium effort: round 1 is `/review <PR number>`
from the authoring checkout. Necessary later rounds are read-only and limited
to repairs since the last reviewed head. Claude-authored work gets Codex review
by branch name without leaving its assigned checkout.

`cross-agent-review` owns finding triage, rejected findings, proportional
re-review, post-review commit classification and round limits. Record every
finding's disposition and review coverage on the PR; the author posts the
record when the reviewer cannot. Credit repair commits with
`Co-Authored-By: Claude <noreply@anthropic.com>` or
`Co-Authored-By: Codex <noreply@openai.com>`. Evidence-backed rejection needs no
reviewer agreement, but formal blocking reviews and GitHub protections remain.

### Ready gate and refresh points

Keep one delivery record. Refresh after a push or recorded review, immediately
before/after Ready, immediately before merge/auto-merge, and whenever head,
feedback, checks, ownership or policy invalidate evidence. Fetch the remote head,
thread-aware unresolved feedback, latest reviews and their SHAs, required checks,
draft state, mergeability and blocking-review state. Reuse unaffected evidence.

Ready requires the intended current remote head, passing required checks,
complete review coverage or a documented behavior-neutral repair disposition,
all findings triaged, no unresolved blocking feedback or applicable
`CHANGES_REQUESTED`, and clean mergeability. Mark non-draft only after these
conditions pass. If a gate fails after Ready, return to draft and repair the
specific gap; a resolved comment does not clear a formal blocking review.

### Owner approval, checks, and merge

CODEOWNERS requests `kamkie` for non-owner-authored PRs. Owner-authored PRs use
the active temporary policy's new `merge PR <number> at <sha>` instruction after
Ready, because GitHub cannot record owner self-approval. Otherwise require the
latest owner's approval at the current head. Never reuse stale authority.

Immediately before integration, refresh the same Ready evidence plus the
applicable current-head owner authorization and non-draft state. Merge as
`kamkie` with `--merge --match-head-commit <sha>`. If all other gates pass and
only required checks remain pending, guarded auto-merge with those flags is
permitted. Otherwise report the exact unmet gate; do not bypass protection.

After merge, fetch `origin/main`, prove the landed result reachable and report
its commit, then complete the global cleanup contract. For an explicitly
requested stack integration into another target, prove that target instead;
merging into a parent branch does not establish arrival on `main`. Live
installation remains separately authorized.

### Delegated work inherits the whole workflow

Delegation carries the discovered base/ownership, scope and this repository's
validation, publication, review, Ready and merge/deployment limits. Reference
these canonical rules instead of copying another gate list. The coordinator
verifies the handoff and completes missing authorized stages.
