---
name: cross-agent-review
description: Have the opposite agent engine attack a committed change, then triage every finding, fix it in credited commits, and re-review in bounded rounds. Use when Claude should be reviewed by Codex or Codex by Claude before handoff, and when review findings must be triaged and fixed rather than only reported. Do not use for same-engine review, security-only audits, rescuing a blocked implementation, or reviewing uncommitted work.
---

# Cross-agent review

One engine implements, the opposite engine attacks, the implementer decides. The
reviewer never edits files. The implementer never grades its own work.

This skill owns the loop, not the reviewer: each direction delegates to the
runtime that already exists for it.

## Before the first round

1. Read the active repository's `AGENTS.md`, `CLAUDE.md`, or equivalent
   checked-in instructions. Repository policy outranks this skill and owns
   validation commands, branch naming, commit trailers, and pull-request gates.
2. If `HEAD` is on the default branch, create an agent-owned branch first, using
   the naming convention that repository defines. Do not invent a prefix.
3. Commit everything in scope. The script refuses a dirty tree.

## Run a round

Write the focus file, then run one round. Resolve `$skill` to this file's
directory.

```powershell
@(
    '<what this change is meant to do, in one sentence>',
    '<each unresolved finding carried forward, with the reason you did not fix it>',
    'Finish with one line: ANOTHER ROUND: yes or no, plus one sentence of justification.'
) -join [Environment]::NewLine | Set-Content -LiteralPath "$env:TEMP/cross-agent-focus.md" -Encoding utf8

pwsh -NoProfile -File "$skill/scripts/Invoke-CrossAgentReview.ps1" `
    -Direction to-codex -FocusFile "$env:TEMP/cross-agent-focus.md"
```

```bash
bash "$skill/scripts/invoke-cross-agent-review.sh" \
    --direction to-codex --focus-file "${TMPDIR:-/tmp}/cross-agent-focus.md"
```

- `-Direction`/`--direction`: `to-codex` when Claude implements, `to-claude` when
  Codex implements.
- **Drop the second line in round 1** — nothing is carried forward yet. Sending
  the placeholder as literal text produces a bogus prompt.
- Omit the base in round 1. In every later round pass `-Base`/`--base` with the
  head the previous round reviewed, so the reviewer sees only the fixes.
- `to-claude` requires an open pull request and reviews the whole PR. It takes no
  supplementary prompt, so the focus file does not reach that reviewer — see the
  escalation rule in the reference below. It also cannot post to the pull
  request: record the result yourself when the repository expects review
  evidence on the PR.
- Keep the focus file outside the repository.

The script pins the range, verifies the reviewed head on both sides of the
invocation, and fails the round if the reviewer exits nonzero or the head moved.
A failed round is not a review; do not count it.

Reviewer output goes to **stderr**; stdout is exactly one JSON object with the
`base`, `head`, and `pullRequest` actually reviewed. On the `to-codex` contract
the round vote has no schema field, so read `ANOTHER ROUND` from the reviewer's
`summary` or `next_steps` text — and when it is absent or unparseable, record no
vote rather than inferring one from the verdict.

## Then judge

The script cannot do this part. Read
[the round loop](references/round-loop.md) for the full contract — it owns
classification, carry-forward, the escalation matrix, the handoff block, and the
report format. In short:

- Classify every finding yourself as confirmed, plausible, or false positive.
  Never "fix" a false positive.
- Commit one fix per finding, crediting the reviewing engine with the trailer the
  repository defines, or `Co-Authored-By: Codex <noreply@openai.com>` /
  `Co-Authored-By: Claude <noreply@anthropic.com>`.
- Run the repository's own validation commands before the round ends.
- Another round only if this one produced a confirmed finding **and** the fixes
  changed the diff. Both sides vote; the implementer decides; three rounds max.
- Anything the loop cannot resolve is escalated to the user, not dropped. A
  commit landing after the last review blocks the handoff.

Reviewing a branch with no pull request is the uncommon path: build a read-only
`-PromptFile` run from [the reviewer stance](references/reviewer-stance.md).
