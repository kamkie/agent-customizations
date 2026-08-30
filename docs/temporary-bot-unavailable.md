# Temporary bot-unavailable pull-request policy

Load this policy immediately before creating or mutating a pull request while
the repository's `AGENTS.md` says the bot-unavailable rule is active.

## Lifecycle

- **Owner:** the repository owner named below.
- **Activation source:** the active notice in the repository's `AGENTS.md`.
- **Review checkpoint:** re-read that notice and this policy immediately before
  every author-side pull-request mutation. Do not carry an earlier session's
  conclusion forward.
- **Exit condition:** the owner confirms that the bot identity is available and
  removes the active notice from `AGENTS.md` in a reviewed change.
- **Stale or conflicting state:** stop before the pull-request mutation and ask
  the owner to resolve the policy state. Do not infer that bot availability or
  an absent credential ends the policy.

`kamkie` is the repository owner, reviewer, approver, and administrator.
`kamkie-codex-bot` is temporarily unavailable. Do not retrieve, restore, or use
its GitHub CLI credential until this notice is removed.

## Author-side mutations

While this policy is active, `kamkie` opens all agent-authored pull requests and
performs author-side mutations. Commits and pushes may use the configured Git or
SSH credentials because pull-request authorship is determined by the credential
that creates the pull request.

Before pull-request creation or another author-side mutation, verify the
effective login:

```powershell
if ((gh api user --jq .login) -ne 'kamkie') {
    throw 'Expected the kamkie GitHub identity while the bot is unavailable.'
}
gh pr create --draft # supply the task-specific base, head, title, and body
```

Do not print authentication tokens, place them in repository files or process
arguments, or globally switch the active GitHub account. If the effective login
is not `kamkie`, stop before the mutation and report the exact blocker.

## Exact-head merge authorization

A pull request authored by `kamkie` cannot receive owner self-approval. After
every other repository gate passes, report the exact current head and leave the
pull request unmerged until the user explicitly instructs `merge PR <number> at
<sha>`.

That exact-head instruction replaces only the unavailable owner self-review. It
does not waive opposite-agent review, finding triage, required checks, readiness,
clean mergeability, or the requirement to refresh the head and review state
immediately before merge. If the head changes, obtain a new exact-head
instruction.

When every other gate passes and the exact-head instruction matches, merge as
`kamkie` using the repository's merge-commit method and
`--match-head-commit <sha>`. If checks are still pending, enable guarded
auto-merge with `--merge --match-head-commit <sha>` instead of bypassing
protection.
