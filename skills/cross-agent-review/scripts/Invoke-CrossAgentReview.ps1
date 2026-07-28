#Requires -Version 7
<#
.SYNOPSIS
Run one cross-agent review round against a committed range.

.DESCRIPTION
Resolves and pins the review range, invokes the opposite engine's reviewer, and
fails the round rather than reporting a review that did not happen. Emits a JSON
result object. Judgment - triage, fixes, and the round decision - stays with the
calling agent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('to-codex', 'to-claude')][string]$Direction,
    [Parameter(Mandatory)][string]$FocusFile,
    [string]$Base,
    [string]$ModelAlias = 'opus',
    [string]$Effort = 'medium'
)

$ErrorActionPreference = 'Stop'

function Invoke-CheckedGit {
    param([Parameter(Mandatory)][string[]]$GitArguments, [Parameter(Mandatory)][string]$FailureMessage)
    $value = & git @GitArguments
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { throw $FailureMessage }
    return ($value | Select-Object -First 1).Trim()
}

function Assert-PullRequestHead {
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][string]$ExpectedHead)
    $prHead = & gh pr view $Number --json headRefOid --jq .headRefOid
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($prHead)) { throw 'Cannot read the pull request head.' }
    $prHead = $prHead.Trim()
    if ($prHead -ne $ExpectedHead) {
        throw "Pull request head is $prHead, not the reviewed head $ExpectedHead. Push the reviewed head, or rerun against the pull request's head."
    }
}

if (-not (Test-Path -LiteralPath $FocusFile -PathType Leaf)) { throw "Focus file not found: $FocusFile" }
$focus = (Get-Content -LiteralPath $FocusFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($focus)) { throw 'The focus file is empty. State the change intent at minimum.' }

$repo = Invoke-CheckedGit @('rev-parse', '--show-toplevel') 'Run from inside the target repository.'

$dirty = & git status --porcelain
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the working tree state.' }
if (-not [string]::IsNullOrWhiteSpace($dirty)) {
    throw 'Uncommitted changes present. Review runs on committed state; commit first.'
}

if ([string]::IsNullOrWhiteSpace($Base)) {
    $defaultRef = Invoke-CheckedGit @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD') `
        'Cannot resolve the default branch. Pass -Base explicitly instead of guessing a name.'
    $defaultBranch = $defaultRef -replace '^origin/', ''
    $reviewBase = Invoke-CheckedGit @('merge-base', "origin/$defaultBranch", 'HEAD') `
        "No merge base between origin/$defaultBranch and HEAD."
} else {
    $reviewBase = Invoke-CheckedGit @('rev-parse', '--verify', "$Base^{commit}") "Cannot resolve base ref: $Base"
}

$reviewHead = Invoke-CheckedGit @('rev-parse', 'HEAD') 'Cannot resolve HEAD.'
if ($reviewBase -eq $reviewHead) { throw 'Nothing committed to review in this range.' }

$pullRequest = 0

if ($Direction -eq 'to-codex') {
    $claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    $companion = Get-ChildItem -Path (Join-Path $claudeHome 'plugins') -Filter 'codex-companion.mjs' `
        -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $companion) { throw 'Install and authenticate the codex plugin before a cross-agent review.' }

    & node $companion.FullName adversarial-review --wait --scope branch --base $reviewBase $focus
    $reviewerExit = $LASTEXITCODE
} else {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $runner = Join-Path $codexHome 'skills/claude-runner/scripts/Invoke-ClaudeRunner.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
        throw 'Install the claude-runner skill before a cross-agent review.'
    }

    $prNumberRaw = & gh pr view --json number --jq .number
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($prNumberRaw)) {
        throw 'Open the pull request first; the read-only reviewer mode reviews a PR, not a bare branch.'
    }
    $pullRequest = [int]$prNumberRaw.Trim()

    # The reviewer reads the pull request's remote head, so a local HEAD check
    # alone would miss unpushed repairs or another actor's push.
    Assert-PullRequestHead -Number $pullRequest -ExpectedHead $reviewHead
    & $runner -WorkingDirectory $repo -ReviewPr $pullRequest -ModelAlias $ModelAlias -Effort $Effort
    $reviewerExit = $LASTEXITCODE
    Assert-PullRequestHead -Number $pullRequest -ExpectedHead $reviewHead
}

# Capture the reviewer's status before any other command overwrites it: a called
# script returning nonzero does not stop its caller.
if ($reviewerExit -ne 0) {
    throw "The reviewer exited with $reviewerExit. No review was produced; this round does not count."
}

$currentHead = Invoke-CheckedGit @('rev-parse', 'HEAD') 'Cannot resolve HEAD.'
if ($currentHead -ne $reviewHead) {
    throw 'HEAD moved during the review. Discard this round and rerun it against the new head.'
}

[pscustomobject]@{
    direction    = $Direction
    repository   = $repo
    base         = $reviewBase
    head         = $reviewHead
    pullRequest  = $pullRequest
    reviewerExit = $reviewerExit
    result       = 'reviewed'
} | ConvertTo-Json -Depth 3
