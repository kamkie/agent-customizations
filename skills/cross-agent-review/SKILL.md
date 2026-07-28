---
name: cross-agent-review
description: Have the opposite agent engine attack a committed change, then triage every finding, fix it in credited commits, and re-review in bounded rounds. Use when Claude should be reviewed by Codex or Codex by Claude before handoff, and when review findings must be triaged and fixed rather than only reported. Do not use for same-engine review, security-only audits, rescuing a blocked implementation, or reviewing uncommitted work.
---

# Cross-agent review

One engine implements, the opposite engine attacks, the implementer decides. The
reviewer never edits files. The implementer never grades its own work.

This skill owns the loop. It does not own the reviewer: each direction delegates
to the runtime that already exists for it.

## Before the first round

1. Read the active repository's `AGENTS.md`, `CLAUDE.md`, or equivalent
   checked-in instructions. Repository policy outranks this skill and owns
   validation commands, branch naming, commit trailers, and pull-request gates.
2. If `HEAD` is on the default branch, create an agent-owned branch first
   (`claude/<short-task-slug>` or `codex/<short-task-slug>`).
3. Commit every change in scope. Review always runs on committed state; nothing
   uncommitted is reviewable.
4. Record the round's base and head.

Resolve the range explicitly. Never let a failed Git call become an empty
argument: an empty `--base` value silently shifts every argument after it, so the
focus text becomes the base ref and the review runs against the wrong range.

```powershell
function Get-CheckedGitValue {
    param([Parameter(Mandatory)][string[]]$GitArguments, [Parameter(Mandatory)][string]$FailureMessage)
    $value = & git @GitArguments
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { throw $FailureMessage }
    return $value.Trim()
}

$repo = Get-CheckedGitValue @('rev-parse', '--show-toplevel') 'Run from inside the target repository.'
$defaultRef = Get-CheckedGitValue @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD') `
    'Cannot resolve the default branch. Pass it explicitly instead of guessing a name.'
$defaultBranch = $defaultRef -replace '^origin/', ''
$reviewBase = Get-CheckedGitValue @('merge-base', "origin/$defaultBranch", 'HEAD') `
    "No merge base between origin/$defaultBranch and HEAD."
$reviewHead = Get-CheckedGitValue @('rev-parse', 'HEAD') 'Cannot resolve HEAD.'
if ($reviewBase -eq $reviewHead) { throw 'Nothing committed to review on this branch.' }
```

`$reviewBase` and `$reviewHead` are the round's contract. Pass both to the
reviewer, and confirm `HEAD` still equals `$reviewHead` when the round returns:

```powershell
$currentHead = Get-CheckedGitValue @('rev-parse', 'HEAD') 'Cannot resolve HEAD.'
if ($currentHead -ne $reviewHead) { throw 'HEAD moved during the review. Rerun this round against the new head.' }
```

A round whose head moved reviewed a different change than the one you are about
to triage. Discard it and rerun rather than triaging findings against code the
reviewer did not see.

Round 1 reviews `$reviewBase..$reviewHead`. Every later round sets `$reviewBase`
to the head the previous round reviewed, so the reviewer sees only the fixes.

## Run one round

Pick the branch for the engine you are running as. Run exactly one reviewer
invocation per round.

### Claude implementing, Codex reviewing

The Codex plugin ships the adversarial reviewer, its prompt, and a structured
output schema. Call it directly; do not restate the stance.

```powershell
$claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$companion = Get-ChildItem -Path (Join-Path $claudeHome 'plugins') -Filter 'codex-companion.mjs' -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $companion) { throw 'Install and authenticate the codex plugin before a cross-agent review.' }
node $companion.FullName adversarial-review --wait --scope branch --base $reviewBase '<what this change is meant to do>'
```

Replace `<what this change is meant to do>` with the change's intent in one
sentence. The reviewer returns `verdict`, `summary`, `findings[]` with
`severity`, `file`, `line_start`, `line_end`, `confidence`, and `recommendation`,
plus `next_steps`.

### Codex implementing, Claude reviewing

Use the `claude-runner` skill; read its `SKILL.md` for the runner path, session
handling, and recovery rules.

```powershell
& $runner -WorkingDirectory $repo -ReviewPr $pr -ModelAlias opus -Effort medium
```

`-ReviewPr` is read-only and needs an open pull request. When the branch has no
pull request yet, either open the draft pull request first or run a read-only
review with `-PromptFile` built from
[the reviewer stance](references/reviewer-stance.md). Never add
`-BypassPermissions` for a review.

`-ReviewPr` cannot post to the pull request, so record the result yourself when
the repository expects the review on the PR.

## Triage every finding yourself

Do not accept the reviewer's verdict. Read the actual code behind each finding
and classify it:

- **confirmed** — you verified the defect is real; state why.
- **plausible** — could be real, not cheaply verifiable; say what would settle it.
- **false positive** — one-line reason.

Never "fix" a false positive. Fix all confirmed findings. Fix plausible ones only
when the fix is small, safe, and obviously harmless. Findings outside the
change's scope get reported, not fixed.

## Commit fixes with reviewer credit

One commit per finding, so the next round can review the repairs in isolation.
Credit the reviewing engine with the trailer the active repository defines; when
it defines none, use the reviewer's standard trailer:

```
Co-Authored-By: Codex <noreply@openai.com>
Co-Authored-By: Claude <noreply@anthropic.com>
```

Run the repository's own validation commands before the round ends. Discover
them from the repository's instructions; do not assume a build system.

## Decide whether to run another round

Rounds are bounded at three and are not automatic.

1. A next round happens only when this round produced at least one confirmed
   finding **and** the fixes actually changed the diff. If nothing changed,
   stop — re-reviewing an unchanged diff returns the same findings.
2. Both sides vote. The reviewer's vote comes back with its findings, so it
   costs nothing extra; ask for it in the same invocation. The implementer votes
   on whether the fixes warrant another look.
3. **The implementer decides.** If the reviewer voted to continue and the
   implementer stops, the report must state that disagreement explicitly.
4. A finding that survives two rounds of disagreement is escalated to the user as
   a decision, not re-litigated in a third round.

Small or low-risk changes finish in one round. Use round 3 as an escape hatch,
not a default.

## Report

Finish with:

1. A table: severity | file:line | verdict (confirmed/plausible/false positive) |
   action (fixed/skipped/escalated) | fix commit.
2. How many rounds ran and why the loop stopped: clean round, no diff change,
   ceiling reached, or unresolved disagreement.
3. Any reviewer-versus-implementer vote disagreement, stated plainly.
4. Validation commands that ran, and any that could not run and why.
