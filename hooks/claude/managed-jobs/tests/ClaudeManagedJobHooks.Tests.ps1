[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$hookRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\..')).Path
$controller = Join-Path $repositoryRoot 'skills\managed-jobs\scripts\Invoke-ManagedJob.ps1'
$common = Join-Path $repositoryRoot 'skills\managed-jobs\scripts\ManagedJob.Common.ps1'
$stopHook = Join-Path $hookRoot 'ManagedJob.StopHook.ps1'
$sessionEndHook = Join-Path $hookRoot 'ManagedJob.SessionEndHook.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('claude-managed-job-hooks-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $testRoot 'state'
$activeIds = [Collections.Generic.List[string]]::new()
$assertionCount = 0
$previousClaudeHome = $env:CLAUDE_CONFIG_DIR
$previousSessionId = $env:CLAUDE_CODE_SESSION_ID
$previousCodexThreadId = $env:CODEX_THREAD_ID
$previousStateRoot = $env:MANAGED_JOBS_ROOT

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:assertionCount++
}

function Get-JobStatus {
    param([string]$Id)
    (& $controller status -Id $Id -StateRoot $stateRoot | Out-String) | ConvertFrom-Json
}

function Wait-JobRunning {
    param([string]$Id)
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    do {
        $job = Get-JobStatus -Id $Id
        if ($job.status -eq 'running') { return $job }
        Start-Sleep -Milliseconds 100
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Id to run; last status was $($job.status)."
}

try {
    $null = New-Item -ItemType Directory -Path $stateRoot -Force
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $sessionId = 'claude-hook-session'
    $env:CLAUDE_CONFIG_DIR = $repositoryRoot
    $env:CLAUDE_CODE_SESSION_ID = $sessionId
    Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
    $env:MANAGED_JOBS_ROOT = $stateRoot
    . $common
    Set-ManagedJobStateRoot -Path $stateRoot

    $turnJob = (& $controller start -StateRoot $stateRoot -Name 'hook-turn-owned' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') | Out-String) | ConvertFrom-Json
    $activeIds.Add($turnJob.id)
    $turnJob = Wait-JobRunning -Id $turnJob.id
    Assert-True ($turnJob.ownerAgent -eq 'claude' -and $turnJob.lifetime -eq 'turn') 'A Claude installation should record Claude turn ownership automatically.'
    $stopPayload = [ordered]@{
        hook_event_name = 'Stop'; session_id = $sessionId; cwd = $testRoot; stop_hook_active = $false
    } | ConvertTo-Json -Compress
    $stopOutput = ('' | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook -ManagedHookId managed-jobs-stop | Out-String)
    Assert-True ([string]::IsNullOrWhiteSpace($stopOutput)) 'Successful Stop cleanup should use the environment when stdin is empty and emit no context.'
    $activeIds.Remove($turnJob.id) | Out-Null
    Assert-True ((Get-JobStatus -Id $turnJob.id).status -eq 'stopped') 'The Stop hook should terminate a turn-owned process tree.'

    # A nested Claude session leaks the outer CLAUDE_CODE_SESSION_ID into hook
    # processes; the payload session identity must win over the environment.
    $nestedJob = (& $controller start -StateRoot $stateRoot -Name 'hook-nested-owned' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') | Out-String) | ConvertFrom-Json
    $activeIds.Add($nestedJob.id)
    $nestedJob = Wait-JobRunning -Id $nestedJob.id
    $env:CLAUDE_CODE_SESSION_ID = 'outer-claude-session'
    $nestedStopOutput = ($stopPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook | Out-String)
    $env:CLAUDE_CODE_SESSION_ID = $sessionId
    Assert-True ([string]::IsNullOrWhiteSpace($nestedStopOutput)) 'Stop cleanup should prefer the payload session over an inherited environment value.'
    $activeIds.Remove($nestedJob.id) | Out-Null
    Assert-True ((Get-JobStatus -Id $nestedJob.id).status -eq 'stopped') 'Payload-identified cleanup should terminate the turn-owned process tree.'

    $sessionJobs = @(
        foreach ($index in 1..4) {
            $sessionJob = (& $controller start -StateRoot $stateRoot -Name "hook-session-owned-$index" -Executable $pwsh `
                -Arguments @('-NoProfile', '-Command', "Write-Output session-$index; Start-Sleep -Seconds 30") -Lifetime Session | Out-String) | ConvertFrom-Json
            $activeIds.Add($sessionJob.id)
            Wait-JobRunning -Id $sessionJob.id
        }
    )
    $sessionPayload = [ordered]@{ hook_event_name = 'SessionEnd'; session_id = $sessionId; cwd = $testRoot; reason = 'exit' } | ConvertTo-Json -Compress
    $sessionTimer = [Diagnostics.Stopwatch]::StartNew()
    $sessionOutput = ($sessionPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $sessionEndHook -ManagedHookId managed-jobs-session-end 2>&1 | Out-String)
    $sessionTimer.Stop()
    Assert-True ([string]::IsNullOrWhiteSpace($sessionOutput)) 'Successful SessionEnd cleanup should emit no context.'
    Assert-True ($sessionTimer.Elapsed.TotalSeconds -lt 3) 'SessionEnd should clean several owned jobs within the registered timeout.'
    foreach ($sessionJob in $sessionJobs) {
        $activeIds.Remove($sessionJob.id) | Out-Null
        Assert-True ((Get-JobStatus -Id $sessionJob.id).status -eq 'stopped') 'The SessionEnd hook should terminate every session-owned process tree.'
    }

    $unclaimedId = '20000101-000000-hook-owned-starting-000001'
    $unclaimedRecord = [ordered]@{
        schemaVersion = 3; id = $unclaimedId; name = 'hook-owned-starting'; kind = 'test'; status = 'starting'
        lifetime = 'turn'; ownerAgent = 'claude'; ownerSessionId = $sessionId; visible = $false; keepTerminalOpen = $false
        processContainment = 'pending'; createdAtUtc = [datetime]::UtcNow.ToString('o'); startedAtUtc = $null; finishedAtUtc = $null
        hostPid = $null; hostStartedAtUtc = $null; executable = 'fixture'; argumentCount = 0; environmentNames = @()
        invocationFingerprint = ('5' * 64); workingDirectory = $testRoot; logPath = (Join-Path $stateRoot "logs\$unclaimedId.log")
        exitCode = $null; error = $null
    }
    $unclaimedRecord | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot "jobs\$unclaimedId.json") -Encoding utf8
    Register-ManagedJobOwnerReference -Job ([pscustomobject]$unclaimedRecord)
    $blockedOutput = ($stopPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook | Out-String) | ConvertFrom-Json
    Assert-True ($blockedOutput.decision -eq 'block') 'Stop cleanup should ask Claude to continue when an owned process cannot be verified.'
    Assert-True ($blockedOutput.reason -match 'hook-owned-starting') 'Blocked cleanup should clearly name the affected job.'
    Assert-True ($blockedOutput.PSObject.Properties.Name -notcontains 'continue') 'Stop cleanup must not suppress its own continuation decision.'
    $continuedPayload = [ordered]@{
        hook_event_name = 'Stop'; session_id = $sessionId; cwd = $testRoot; stop_hook_active = $true
    } | ConvertTo-Json -Compress
    $boundedOutput = ($continuedPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook | Out-String) | ConvertFrom-Json
    Assert-True ($boundedOutput.systemMessage -match 'will not block the turn again') 'A repeated cleanup failure should warn without creating a Stop-hook loop.'
    Assert-True ($boundedOutput.PSObject.Properties.Name -notcontains 'decision') 'A repeated cleanup failure should allow the turn to end.'
    Unregister-ManagedJobOwnerReference -Job ([pscustomobject]$unclaimedRecord)
    Remove-Item -LiteralPath (Join-Path $stateRoot "jobs\$unclaimedId.json") -Force

    $env:CLAUDE_CONFIG_DIR = Join-Path $testRoot 'missing-claude-home'
    $infrastructureFirst = ($stopPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook | Out-String) | ConvertFrom-Json
    Assert-True ($infrastructureFirst.decision -eq 'block') 'The first hook infrastructure failure should give Claude one chance to recover.'
    $infrastructureBounded = ($continuedPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook | Out-String) | ConvertFrom-Json
    Assert-True ($infrastructureBounded.systemMessage -match 'will not block the turn again') 'A repeated hook infrastructure failure should degrade to one clear warning.'
    Assert-True ($infrastructureBounded.PSObject.Properties.Name -notcontains 'decision') 'A repeated infrastructure failure must not wedge the turn.'
    $env:CLAUDE_CONFIG_DIR = $repositoryRoot

    $launchGuard = Join-Path $repositoryRoot 'skills\managed-jobs\scripts\ManagedJob.PreToolUseHook.ps1'
    $backgroundPayload = [ordered]@{
        hook_event_name = 'PreToolUse'; tool_name = 'Bash'
        tool_input = [ordered]@{ command = 'python -m http.server'; run_in_background = $true }
    } | ConvertTo-Json -Compress
    $backgroundDecision = ($backgroundPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $launchGuard | Out-String) | ConvertFrom-Json
    Assert-True ($backgroundDecision.hookSpecificOutput.permissionDecision -eq 'deny') 'The launch guard should deny a natively backgrounded command.'
    $foregroundPayload = [ordered]@{
        hook_event_name = 'PreToolUse'; tool_name = 'PowerShell'
        tool_input = [ordered]@{ command = 'git status' }
    } | ConvertTo-Json -Compress
    $foregroundOutput = ($foregroundPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $launchGuard | Out-String)
    Assert-True ([string]::IsNullOrWhiteSpace($foregroundOutput)) 'The launch guard should stay silent for an ordinary foreground command.'

    Remove-Item Env:CLAUDE_CODE_SESSION_ID -ErrorAction SilentlyContinue
    $payloadStopOutput = ($stopPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook | Out-String)
    Assert-True ([string]::IsNullOrWhiteSpace($payloadStopOutput)) 'Stop cleanup should use payload.session_id when CLAUDE_CODE_SESSION_ID is absent.'
    $payloadSessionOutput = ($sessionPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $sessionEndHook 2>&1 | Out-String)
    Assert-True ([string]::IsNullOrWhiteSpace($payloadSessionOutput)) 'SessionEnd cleanup should use payload.session_id when CLAUDE_CODE_SESSION_ID is absent.'
    $env:CLAUDE_CODE_SESSION_ID = $sessionId

    [pscustomobject]@{
        result = 'passed'
        assertions = $assertionCount
        sessionCleanupSeconds = [math]::Round($sessionTimer.Elapsed.TotalSeconds, 3)
        isolatedStateRoot = $stateRoot
    } | ConvertTo-Json
} finally {
    foreach ($id in @($activeIds)) {
        try { & $controller stop -StateRoot $stateRoot -Id $id | Out-Null } catch {}
    }
    if ($testRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $testRoot) -like 'claude-managed-job-hooks-*') {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($entry in @(
        @{ Name = 'CLAUDE_CONFIG_DIR'; Value = $previousClaudeHome },
        @{ Name = 'CLAUDE_CODE_SESSION_ID'; Value = $previousSessionId },
        @{ Name = 'CODEX_THREAD_ID'; Value = $previousCodexThreadId },
        @{ Name = 'MANAGED_JOBS_ROOT'; Value = $previousStateRoot }
    )) {
        if ($null -eq $entry.Value) {
            Remove-Item "Env:$($entry.Name)" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($entry.Name, [string]$entry.Value, 'Process')
        }
    }
}
