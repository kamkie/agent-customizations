param([string]$ManagedHookId)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$stateRoot = Join-Path ([IO.Path]::GetTempPath()) 'codex-git-closeout'

function Get-Worktrees([string]$Repository) {
    $output = git --no-optional-locks -C $Repository worktree list --porcelain -z 2>$null
    if ($LASTEXITCODE -ne 0) { return }
    foreach ($entry in (($output -join "`n") -split "`0`0")) {
        $fields = $entry -split "`0"
        if ($fields[0] -notlike 'worktree *') { continue }
        $branch = $fields | Where-Object { $_ -like 'branch *' }
        [pscustomobject]@{ Path = [IO.Path]::GetFullPath($fields[0].Substring(9)); Branch = $branch }
    }
}

function Remove-TurnState($State, [string]$StatePath) {
    [IO.File]::Delete($StatePath)
    if ($State.inventory -match '^[0-9a-f]{32}\.inventory\.json$') {
        [IO.File]::Delete((Join-Path $stateRoot $State.inventory))
    }
}

function Get-CloseoutIssue($State) {
    if ($State.inventory -notmatch '^[0-9a-f]{32}\.inventory\.json$') { throw 'Invalid inventory name.' }
    $inventoryPath = Join-Path $stateRoot $State.inventory
    if (-not [IO.File]::Exists($inventoryPath)) {
        'The verified merge commit and local cleanup inventory have not been recorded.'
        return
    }
    $plan = Get-Content -LiteralPath $inventoryPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($plan -isnot [System.Collections.IDictionary] -or
        $plan.landedCommit -isnot [string] -or $plan.landedCommit -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$' -or
        $plan.branches -isnot [System.Collections.IList] -or $plan.worktrees -isnot [System.Collections.IList] -or
        ($null -ne $plan.mainCheckout -and ($plan.mainCheckout -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($plan.mainCheckout)))) {
        'The local cleanup inventory is invalid. Supply the landed commit, branch and worktree arrays, and the reusable main checkout path if applicable.'
        return
    }

    $repository = $State.repository
    $target = git --no-optional-locks -C $repository rev-parse --verify refs/remotes/origin/main 2>$null
    if ($LASTEXITCODE -ne 0) {
        'Fetched origin/main is unavailable.'
    } else {
        git --no-optional-locks -C $repository merge-base --is-ancestor $plan.landedCommit $target 2>$null
        if ($LASTEXITCODE -ne 0) { 'Fetched origin/main has not been shown to contain the reported merge.' }

        $localMain = git --no-optional-locks -C $repository rev-parse --verify refs/heads/main 2>$null
        if ($LASTEXITCODE -ne 0 -or $localMain -ne $target) { 'Local main does not match fetched origin/main.' }
    }

    foreach ($branch in $plan.branches) {
        if ($branch -isnot [string] -or -not $branch -or $branch -ceq 'main') {
            'The local cleanup inventory contains an invalid task branch.'
            continue
        }
        git check-ref-format "refs/heads/$branch" 2>$null
        if ($LASTEXITCODE -ne 0) {
            'The local cleanup inventory contains an invalid task branch.'
            continue
        }
        git --no-optional-locks -C $repository show-ref --verify --quiet "refs/heads/$branch" 2>$null
        if ($LASTEXITCODE -eq 0) {
            "Recorded task branch still exists: $branch."
        } elseif ($LASTEXITCODE -ne 1) {
            "Could not check recorded task branch: $branch."
        }
    }

    $worktrees = @(Get-Worktrees $repository)
    if (-not $worktrees.Count) {
        'Could not read the registered worktrees.'
        return
    }
    $pathComparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    foreach ($path in $plan.worktrees) {
        if ($path -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($path)) {
            'The local cleanup inventory contains an invalid worktree path.'
            continue
        }
        $fullPath = [IO.Path]::GetFullPath($path)
        if (($worktrees | Where-Object { $pathComparer.Equals($_.Path, $fullPath) }) -or (Test-Path -LiteralPath $fullPath)) {
            "Recorded task worktree still exists: $fullPath."
        }
    }

    $mainWorktree = $worktrees | Where-Object Branch -CEQ 'branch refs/heads/main'
    $expectedCheckout = $State.mainCheckout ?? $plan.mainCheckout
    if ($expectedCheckout -and -not $pathComparer.Equals($mainWorktree.Path, [IO.Path]::GetFullPath($expectedCheckout))) {
        'The reusable checkout has not been restored to main.'
    }
    if ($mainWorktree) {
        $status = git --no-optional-locks -c core.fsmonitor=false -C $mainWorktree.Path status --porcelain --untracked-files=normal 2>$null
        if ($LASTEXITCODE -ne 0) {
            'Could not check the local main checkout.'
        } elseif ($status) {
            'The local main checkout has changes.'
        }
    }
}

function Write-StopResult($Payload, $State, [string]$StatePath, [string[]]$Issues) {
    if ($Issues.Count -eq 0 -or $Payload.stop_hook_active -eq $true) {
        Remove-TurnState $State $StatePath
    }
    if ($Issues.Count -eq 0) { return }

    $message = "Local Git closeout is unverified. $($Issues -join ' ')"
    if ($Payload.stop_hook_active -eq $true) {
        @{ systemMessage = $message } | ConvertTo-Json -Compress
    } else {
        @{
            decision = 'block'
            reason = "$message If the report applies to this delivery, complete every safe remaining step now and give the exact blocker for anything outstanding. Preserve unrelated, dirty, active, and unintegrated work. If the report is out of scope, explain that boundary."
        } | ConvertTo-Json -Compress
    }
}

try {
    $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8, $true)
    $payload = $reader.ReadToEnd() | ConvertFrom-Json
    if ($payload -isnot [pscustomobject] -or $payload.session_id -isnot [string] -or -not $payload.session_id) { exit 0 }
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($payload.session_id)))
    $statePath = Join-Path $stateRoot "$key.json"
    $state = if ([IO.File]::Exists($statePath)) { Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json }
    if ($payload.hook_event_name -ceq 'SessionEnd') {
        if ($state) { Remove-TurnState $state $statePath }
        exit 0
    }
    if ($payload.turn_id -isnot [string] -or -not $payload.turn_id) { exit 0 }

    if ($payload.hook_event_name -ceq 'UserPromptSubmit') {
        if ($state -and $state.turnId -cne $payload.turn_id) {
            Remove-TurnState $state $statePath
            $state = $null
        }
        $merged = '(?:(?:it(?:''|\u2019)s\s+)?merged|zmergowane|scalone|zmergowałem|scaliłem)'
        $change = '(?:(?:PR|MR)\s*[#!]?\d+|[#!]\d+)'
        $report = "^\s*(?:$merged(?:\s+$change)?|$change\s+$merged)(?:,\s*(?:thanks|dzięki))?[.!]?\s*$"
        if ($state -or $payload.prompt -isnot [string] -or $payload.prompt -notmatch $report -or
            $payload.cwd -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($payload.cwd)) { exit 0 }

        $worktrees = @(Get-Worktrees $payload.cwd)
        if (-not $worktrees.Count) { exit 0 }
        # The primary worktree survives removal of an attached task worktree.
        $repository = $worktrees[0].Path
        if (-not (Test-Path -LiteralPath $repository -PathType Container)) { exit 0 }
        git --no-optional-locks -C $repository show-ref --verify --quiet refs/heads/main 2>$null
        if ($LASTEXITCODE -ne 0) { exit 0 }
        git --no-optional-locks -C $repository remote get-url origin *> $null
        if ($LASTEXITCODE -ne 0) { exit 0 }

        $null = [IO.Directory]::CreateDirectory($stateRoot)
        $state = [ordered]@{
            turnId = $payload.turn_id
            repository = $repository
            mainCheckout = ($worktrees | Where-Object Branch -CEQ 'branch refs/heads/main').Path
            inventory = [guid]::NewGuid().ToString('N') + '.inventory.json'
        }
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Compress), $utf8)
        $inventoryPath = Join-Path $stateRoot $state.inventory
        $context = @"
If this is the user's merge report for this repository's current delivery to origin/main, follow the global Delivery and cleanup rules and the repository's applicable policy. Fetch and verify the specific landed commit first. Before changing Git state, write the verified landed commit and exact local branches and worktree paths due for cleanup as UTF-8 JSON. Use empty arrays for no remaining branches or worktrees. Supply the reusable checkout path as mainCheckout when it should end on main, or null otherwise. Correct the inventory if you discover an ownership mistake. Do not include another task's resources.
Inventory path: $inventoryPath
JSON shape: {"landedCommit":"<verified full commit ID>","branches":[],"worktrees":[],"mainCheckout":null}
The Stop hook will read Git to verify this inventory. It grants no new publication, merge, or deployment authority.
"@
        @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $context } } |
            ConvertTo-Json -Depth 4 -Compress
    } elseif ($payload.hook_event_name -ceq 'Stop' -and $state.turnId -ceq $payload.turn_id) {
        try {
            $issues = @(Get-CloseoutIssue $state)
        } catch {
            $issues = @('Could not read the cleanup inventory or check the local Git state.')
        }
        Write-StopResult $payload $state $statePath $issues
    }
} catch {
    # An unavailable check must not trap a turn or change the user's Git state.
    if ($state -and $payload.hook_event_name -ceq 'Stop') {
        @{ systemMessage = 'Local Git closeout could not be checked. Verify it before claiming completion.' } | ConvertTo-Json -Compress
    }
}
exit 0
