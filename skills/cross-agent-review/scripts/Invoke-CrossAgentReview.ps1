#Requires -Version 7
<#
.SYNOPSIS
Run one cross-agent review round against a committed range.

.DESCRIPTION
Resolves and pins the review range, invokes the opposite engine's reviewer, and
fails the round rather than reporting a review that did not happen.

The reviewer's own output goes to stderr; stdout carries exactly one JSON object
describing the round, so a caller can parse the range that was actually
reviewed. Judgment - triage, fixes, and the round decision - stays with the
calling agent.

Exit codes: 0 reviewed, 1 round failed, 2 invalid invocation.

Arguments are parsed by hand rather than through a param() block, matching
invoke-cross-agent-review.sh token for token. PowerShell's parameter binder runs
before any script code, so with binding enabled `-?` printed syntax help to
stdout and exited 0 - claiming a completed review that never ran and breaking
the machine-readable stdout contract. Binding also accepted an unlabelled
trailing SHA into -Base, reviewing a range the caller never asked for.

Both long and PowerShell-style spellings are accepted: -Direction and
--direction are equivalent.
#>

$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
Usage: Invoke-CrossAgentReview.ps1 -Direction <to-codex|to-claude> -FocusFile <path>
                                   [-Base <ref>] [-ModelAlias <alias>] [-Effort <level>]
'@ | ForEach-Object { [Console]::Error.WriteLine($_) }
}

function Exit-Invalid { param([string]$Message) Write-Error $Message -ErrorAction Continue; Show-Usage; exit 2 }
function Exit-Failed { param([string]$Message) Write-Error $Message -ErrorAction Continue; exit 1 }

function Assert-Dependency {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Purpose)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Exit-Failed "Missing dependency '$Name', required for $Purpose."
    }
}

function Invoke-CheckedGit {
    param([Parameter(Mandatory)][string[]]$GitArguments, [Parameter(Mandatory)][string]$FailureMessage)
    $value = & git @GitArguments
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) { Exit-Failed $FailureMessage }
    return ($value | Select-Object -First 1).Trim()
}

function Assert-PullRequestHead {
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][string]$ExpectedHead)
    $prHead = & gh pr view $Number --json headRefOid --jq .headRefOid
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($prHead)) { Exit-Failed 'Cannot read the pull request head.' }
    $prHead = $prHead.Trim()
    if ($prHead -ne $ExpectedHead) {
        Exit-Failed "Pull request head is $prHead, not the reviewed head $ExpectedHead. Push the reviewed head, or rerun against the pull request's head."
    }
}

# --- invocation validation (exit 2), matching invoke-cross-agent-review.sh ----
$Direction = ''
$FocusFile = ''
$Base = ''
$ModelAlias = 'opus'
$Effort = 'medium'

$index = 0
while ($index -lt $args.Count) {
    $token = [string]$args[$index]
    $name = ($token -replace '^-{1,2}', '').ToLowerInvariant() -replace '-', ''

    if ($token -in @('-?', '-h', '--help')) { Show-Usage; exit 2 }
    if ($token -notmatch '^-{1,2}[A-Za-z]') { Exit-Invalid "Unknown argument: $token" }
    if ($name -notin @('direction', 'focusfile', 'base', 'modelalias', 'effort')) {
        Exit-Invalid "Unknown argument: $token"
    }
    # Validate arity before consuming the value, so a trailing option reports
    # usage instead of silently binding nothing.
    if ($index + 1 -ge $args.Count) { Exit-Invalid "Option $token requires a value." }

    $value = [string]$args[$index + 1]
    switch ($name) {
        'direction'  { $Direction = $value }
        'focusfile'  { $FocusFile = $value }
        'base'       { $Base = $value }
        'modelalias' { $ModelAlias = $value }
        'effort'     { $Effort = $value }
    }
    $index += 2
}

$Direction = $Direction.ToLowerInvariant()
if ($Direction -notin @('to-codex', 'to-claude')) { Exit-Invalid 'Direction must be to-codex or to-claude.' }
if ([string]::IsNullOrWhiteSpace($FocusFile)) { Exit-Invalid 'A focus file is required.' }
if (-not (Test-Path -LiteralPath $FocusFile -PathType Leaf)) { Exit-Invalid "Focus file not found: $FocusFile" }
$focus = (Get-Content -LiteralPath $FocusFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($focus)) { Exit-Invalid 'The focus file is empty. State the change intent at minimum.' }

# --- preflight, in the same order as the shell implementation ----------------
Assert-Dependency -Name 'git' -Purpose 'range resolution'
if ($Direction -eq 'to-codex') {
    Assert-Dependency -Name 'node' -Purpose 'the Codex plugin runtime'
} else {
    Assert-Dependency -Name 'gh' -Purpose 'pull-request head verification'
}

$repo = Invoke-CheckedGit @('rev-parse', '--show-toplevel') 'Not inside a Git repository. Run from the target repository.'

$dirty = & git status --porcelain
if ($LASTEXITCODE -ne 0) { Exit-Failed 'Cannot read the working tree state; refusing to assume it is clean.' }
if (-not [string]::IsNullOrWhiteSpace($dirty)) {
    Exit-Failed 'Uncommitted changes present. Review runs on committed state; commit first.'
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
if ($reviewBase -eq $reviewHead) { Exit-Failed 'Nothing committed to review in this range.' }

$pullRequest = 0

if ($Direction -eq 'to-codex') {
    # Resolve the plugin through the authoritative installed-plugin manifest.
    # Selecting by file mtime could execute a stale marketplace copy instead of
    # the installed one - a local-code trust boundary, not a convenience.
    $claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    $manifestPath = Join-Path $claudeHome 'plugins/installed_plugins.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Exit-Failed "No installed-plugin manifest at $manifestPath. Install the codex plugin first."
    }
    $installed = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).plugins.'codex@openai-codex'
    if (-not $installed) { Exit-Failed 'The codex@openai-codex plugin is not installed.' }
    if (@($installed).Count -ne 1) { Exit-Failed 'Ambiguous codex@openai-codex installation; resolve it before reviewing.' }
    $companion = Join-Path @($installed)[0].installPath 'scripts/codex-companion.mjs'
    if (-not (Test-Path -LiteralPath $companion -PathType Leaf)) {
        Exit-Failed "The installed codex plugin has no reviewer script at $companion."
    }

    & node $companion adversarial-review --wait --scope branch --base $reviewBase $focus *>&1 |
        ForEach-Object { [Console]::Error.WriteLine([string]$_) }
    $reviewerExit = $LASTEXITCODE
} else {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $runner = Join-Path $codexHome 'skills/claude-runner/scripts/Invoke-ClaudeRunner.ps1'
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
        Exit-Failed 'Install the claude-runner skill before a cross-agent review.'
    }

    $prNumberRaw = & gh pr view --json number --jq .number
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($prNumberRaw)) {
        Exit-Failed 'Open the pull request first; the read-only reviewer mode reviews a PR, not a bare branch.'
    }
    $pullRequest = [int]$prNumberRaw.Trim()

    # The reviewer reads the pull request's remote head, so a local HEAD check
    # alone would miss unpushed repairs or another actor's push.
    Assert-PullRequestHead -Number $pullRequest -ExpectedHead $reviewHead
    & $runner -WorkingDirectory $repo -ReviewPr $pullRequest -ModelAlias $ModelAlias -Effort $Effort *>&1 |
        ForEach-Object { [Console]::Error.WriteLine([string]$_) }
    $reviewerExit = $LASTEXITCODE
}

# Check the reviewer's status before any other command runs: a later failure
# would otherwise report the wrong cause and hide a timeout, crash, or auth
# failure. A called script returning nonzero does not stop its caller.
if ($reviewerExit -ne 0) {
    Exit-Failed "The reviewer exited with $reviewerExit. No review was produced; this round does not count."
}

if ($Direction -eq 'to-claude') { Assert-PullRequestHead -Number $pullRequest -ExpectedHead $reviewHead }

$currentHead = Invoke-CheckedGit @('rev-parse', 'HEAD') 'Cannot resolve HEAD.'
if ($currentHead -ne $reviewHead) {
    Exit-Failed 'HEAD moved during the review. Discard this round and rerun it against the new head.'
}

[pscustomobject]@{
    direction    = $Direction
    repository   = $repo
    base         = $reviewBase
    head         = $reviewHead
    pullRequest  = $pullRequest
    reviewerExit = $reviewerExit
    result       = 'reviewed'
} | ConvertTo-Json -Depth 3 -Compress:$false
