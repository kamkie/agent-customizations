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

Build the focus text from three parts: the change's intent in one sentence, every
unresolved finding carried forward from an earlier round, and this literal
request:

```text
Finish with one line: ANOTHER ROUND: yes or no, plus one sentence of justification.
```

The reviewer returns `verdict`, `summary`, `findings[]` with `severity`, `file`,
`line_start`, `line_end`, `confidence`, and `recommendation`, plus `next_steps`.
That schema has **no field for the round vote**, so the vote can only arrive as
free text inside `summary` or `next_steps`. Read it from there. When it is
missing or unparseable, treat the round as having **no reviewer vote** — never
infer one from the verdict — and record in the report that the implementer
decided without it.

### Codex implementing, Claude reviewing

This direction runs through the `claude-runner` skill and requires an open pull
request: `-ReviewPr` is the read-only reviewer mode.

```powershell
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$runner = Join-Path $codexHome 'skills/claude-runner/scripts/Invoke-ClaudeRunner.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'Install the claude-runner skill before a cross-agent review.' }
$pr = [int](gh pr view --json number --jq .number)
if ($LASTEXITCODE -ne 0 -or $pr -le 0) { throw 'Open the pull request first; -ReviewPr reviews a PR, not a bare branch.' }
& $runner -WorkingDirectory $repo -ReviewPr $pr -ModelAlias opus -Effort medium
```

Never add `-BypassPermissions` to a review. Read `claude-runner`'s own `SKILL.md`
only for session resumption and recovery after an interrupted run.

Two consequences to handle rather than ignore:

- `-ReviewPr` reviews the whole pull request, not the incremental range, so this
  direction re-reads earlier rounds' code. Carrying unresolved findings forward
  still matters, but the diff itself will not hide them.
- `-ReviewPr` cannot post to the pull request. Record the result yourself when
  the repository expects the review on the PR.

Reviewing a branch that has no pull request is the uncommon path: build a
read-only `-PromptFile` run from
[the reviewer stance](references/reviewer-stance.md).

## Triage every finding yourself

Do not accept the reviewer's verdict. Read the actual code behind each finding
and classify it:

- **confirmed** — you verified the defect is real; state why.
- **plausible** — could be real, not cheaply verifiable; say what would settle it.
- **false positive** — one-line reason.

Never "fix" a false positive. Fix all confirmed findings. Fix plausible ones only
when the fix is small, safe, and obviously harmless. Findings outside the
change's scope get reported, not fixed.

### Carry unresolved findings forward

Keep a list of findings you did not fix — every plausible one you left alone and
every one you called a false positive. Later rounds review only the fixes, so an
unfixed finding disappears from the diff and the reviewer cannot raise it again.
Without this list a disputed finding is silently dropped after one round instead
of surviving to the escalation rule below.

Restate each unresolved finding in the next round's focus text, with your reason
for not fixing it, and ask the reviewer to accept or contest that reasoning. A
finding is resolved when it is fixed, when the reviewer accepts your reasoning,
or when it is escalated to the user.

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
2. Both sides vote. Ask for the reviewer's vote inside the review that already
   runs, so it costs nothing extra. Not every reviewer contract has a field for
   it: when no usable vote comes back, record the absence rather than inventing
   one. The implementer votes on whether the fixes warrant another look.
3. **The implementer decides.** If the reviewer voted to continue and the
   implementer stops, the report must state that disagreement explicitly.
4. A finding that survives two rounds of disagreement is escalated to the user as
   a decision, not re-litigated in a third round. This only works when unresolved
   findings are carried forward as above; an incremental diff alone cannot
   surface them a second time.

Small or low-risk changes finish in one round. Use round 3 as an escape hatch,
not a default.

## Report

Finish with:

1. A table: severity | file:line | verdict (confirmed/plausible/false positive) |
   action (fixed/skipped/escalated) | fix commit.
2. How many rounds ran and why the loop stopped: clean round, no diff change,
   ceiling reached, or unresolved disagreement.
3. Whether any commit landed after the last review. Fixes made in the final
   round are not themselves reviewed, so a bounded loop can hand off repair code
   no opposite engine inspected. Name those commits and say plainly that they
   are unreviewed. Do not paper over this by claiming the change is fully
   reviewed.
4. Any reviewer-versus-implementer vote disagreement, and any round where the
   reviewer returned no usable vote.
5. Every unresolved finding, with its classification and the reason it was left.
6. Validation commands that ran, and any that could not run and why.
