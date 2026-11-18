[CmdletBinding()]
param(
    [string]$ManagedHookId,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$Record,
    [string]$TurnId,
    [ValidatePattern('^(?:[0-9a-f]{40}|[0-9a-f]{64})$')][string]$LandedCommit,
    [string[]]$TaskBranch = @()
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$stateRoot = Join-Path $PSScriptRoot 'state'

function Write-State($Path, $State) {
    $temp = Join-Path $stateRoot ([guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temp, ($State | ConvertTo-Json -Depth 4 -Compress))
        [IO.File]::Move($temp, $Path, $true)
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Get-CloseoutIssue($State) {
    if (-not $State.landedCommit) {
        'The verified merge commit and task branch inventory have not been recorded.'
        return
    }

    $repository = $State.repository
    $target = git --no-optional-locks -C $repository rev-parse --verify refs/remotes/origin/main 2>$null
    if ($LASTEXITCODE -ne 0) {
        'Fetched origin/main is unavailable.'
    } else {
        git --no-optional-locks -C $repository merge-base --is-ancestor $State.landedCommit $target 2>$null
        if ($LASTEXITCODE -ne 0) { 'Fetched origin/main has not been shown to contain the reported merge.' }

        $localMain = git --no-optional-locks -C $repository rev-parse --verify refs/heads/main 2>$null
        if ($LASTEXITCODE -ne 0 -or $localMain -ne $target) { 'Local main does not match fetched origin/main.' }
    }

    foreach ($branch in $State.branches) {
        git --no-optional-locks -C $repository show-ref --verify --quiet "refs/heads/$branch" 2>$null
        if ($LASTEXITCODE -eq 0) {
            "Recorded task branch still exists: $branch."
        } elseif ($LASTEXITCODE -ne 1) {
            "Could not check recorded task branch: $branch."
        }
    }

    $worktrees = git --no-optional-locks -C $repository worktree list --porcelain -z 2>$null
    if ($LASTEXITCODE -ne 0) {
        'Could not locate the local main checkout.'
        return
    }
    $checkout = $null
    foreach ($field in (($worktrees -join "`n") -split "`0")) {
        if ($field.StartsWith('worktree ')) {
            $checkout = $field.Substring(9)
        } elseif ($field -ceq 'branch refs/heads/main') {
            $status = git --no-optional-locks -C $checkout status --porcelain --untracked-files=normal 2>$null
            if ($LASTEXITCODE -ne 0) {
                'Could not check the local main checkout.'
            } elseif ($status) {
                'The local main checkout has changes.'
            }
        }
    }
}

if ($Record) {
    if (-not $TurnId -or -not $LandedCommit) {
        throw 'Record requires TurnId and the verified LandedCommit.'
    }
    $statePath = Join-Path $stateRoot "$Record.json"
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.turnId -cne $TurnId) { throw 'The active closeout turn has changed.' }
    foreach ($branch in $TaskBranch) {
        git check-ref-format "refs/heads/$branch" 2>$null
        if (-not $branch -or $branch -ceq 'main' -or $LASTEXITCODE -ne 0) {
            throw "Invalid task branch: $branch"
        }
    }
    $branches = @($TaskBranch | Sort-Object -CaseSensitive -Unique)
    if ($state.landedCommit) {
        if ($state.landedCommit -cne $LandedCommit -or ($state.branches -join "`n") -cne ($branches -join "`n")) {
            throw 'The recorded merge and task branch inventory are fixed for this turn.'
        }
        exit 0
    }
    $state.landedCommit = $LandedCommit
    $state.branches = $branches
    Write-State $statePath $state
    exit 0
}

$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
if ($payload.session_id -isnot [string] -or -not $payload.session_id -or
    $payload.turn_id -isnot [string] -or -not $payload.turn_id) { exit 0 }
$key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($payload.session_id))).ToLowerInvariant()
$statePath = Join-Path $stateRoot "$key.json"

if ($payload.hook_event_name -ceq 'UserPromptSubmit') {
    if ($payload.prompt -isnot [string] -or $payload.prompt -notmatch '^\s*(?:merged|zmergowane|scalone)(?:\s+(?:(?:PR|MR)\s*)?[#!]\d+)?[.!]?\s*$') { exit 0 }
    if ($payload.cwd -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($payload.cwd)) { exit 0 }
    $worktrees = git --no-optional-locks -C $payload.cwd worktree list --porcelain -z 2>$null
    if ($LASTEXITCODE -ne 0) { exit 0 }
    # The primary worktree survives removal of an attached task worktree.
    $repository = ((($worktrees -join "`n") -split "`0", 2)[0]).Substring(9)
    if (-not (Test-Path -LiteralPath $repository -PathType Container)) { exit 0 }
    git --no-optional-locks -C $repository show-ref --verify --quiet refs/heads/main 2>$null
    if ($LASTEXITCODE -ne 0) { exit 0 }
    git --no-optional-locks -C $repository remote get-url origin *> $null
    if ($LASTEXITCODE -ne 0) { exit 0 }

    $null = [IO.Directory]::CreateDirectory($stateRoot)
    Write-State $statePath ([ordered]@{
        turnId = $payload.turn_id
        repository = $repository
        landedCommit = $null
        branches = @()
    })
    $script = $PSCommandPath.Replace("'", "''")
    $turn = $payload.turn_id.Replace("'", "''")
    $context = @"
If this is the user's merge report for this repository's current delivery to origin/main, follow the post-merge closeout in AGENTS.md. Fetch and verify the specific landed commit first. Before changing Git state, record the verified landed commit and the exact local branch names still owned by this session and eligible for cleanup:
& '$script' -Record '$key' -TurnId '$turn' -LandedCommit <verified commit> -TaskBranch @(<exact branch names>)
Use @() if no task branches remain. The Stop hook independently reads local main, fetched origin/main and those branch refs. This check grants no authority outside the delivery.
"@
    @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $context } } |
        ConvertTo-Json -Depth 4 -Compress
    exit 0
}

if ($payload.hook_event_name -cne 'Stop' -or -not [IO.File]::Exists($statePath)) { exit 0 }
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.turnId -cne $payload.turn_id) { exit 0 }

$issues = @(Get-CloseoutIssue $state)
if ($issues.Count -eq 0) {
    [IO.File]::Delete($statePath)
    exit 0
}

$message = "Local Git closeout is unverified. $($issues -join ' ')"
if ($payload.stop_hook_active -eq $true) {
    [IO.File]::Delete($statePath)
    @{ systemMessage = $message } | ConvertTo-Json -Compress
} else {
    @{
        decision = 'block'
        reason = "$message If the report applies to this delivery, complete every safe remaining step now and give the exact blocker for anything outstanding. Preserve unrelated, dirty, active, and unintegrated work. If the report is out of scope, explain that boundary."
    } | ConvertTo-Json -Compress
}
