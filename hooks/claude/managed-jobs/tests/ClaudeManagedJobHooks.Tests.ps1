[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$hookRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\..')).Path
$controller = Join-Path $repositoryRoot 'skills\managed-jobs\scripts\Invoke-ManagedJob.ps1'
$common = Join-Path $repositoryRoot 'skills\managed-jobs\scripts\ManagedJob.Common.ps1'
$sessionStartHook = Join-Path $repositoryRoot 'skills\managed-jobs\scripts\ManagedJob.SessionStartHook.ps1'
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
        if ($job.status -in @('completed', 'failed', 'stopped', 'orphaned')) {
            $log = if (Test-Path -LiteralPath $job.logPath -PathType Leaf) {
                Get-Content -LiteralPath $job.logPath -Raw
            } else { '<missing>' }
            throw "Job $Id reached $($job.status) before running. Error: $($job.error) Log: $log"
        }
        Start-Sleep -Milliseconds 100
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Id to run; last status was $($job.status)."
}

function Start-SessionStartHookProcess {
    param([Parameter(Mandatory)][string]$Payload)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sessionStartHook)) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($Payload)
    $process.StandardInput.Close()
    [pscustomobject]@{ process = $process; outputTask = $outputTask; errorTask = $errorTask }
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
    $null = Get-ManagedJobRoot

    $staleId = '20000101-000000-hook-stale-completed-000001'
    $staleRecord = [ordered]@{
        schemaVersion = 4; id = $staleId; name = 'hook-stale-completed'; kind = 'test'; status = 'completed'
        lifetime = 'turn'; ownerAgent = 'claude'; ownerSessionId = $sessionId; visible = $true; sharedTerminal = $true
        terminalControlState = 'released'; keepTerminalOpen = $false; processContainment = 'windows-job-object-kill-on-close'
        createdAtUtc = '2000-01-01T00:00:00Z'; startedAtUtc = '2000-01-01T00:00:01Z'; finishedAtUtc = '2000-01-01T00:00:02Z'
        hostPid = 2147483647; hostStartedAtUtc = '2000-01-01T00:00:01Z'; executable = 'fixture'; argumentCount = 0
        environmentNames = @(); invocationFingerprint = ('9' * 64); workingDirectory = $testRoot
        logPath = (Join-Path $stateRoot "logs\$staleId.log"); exitCode = 0; error = $null
    }
    $staleRecord | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot "jobs\$staleId.json") -Encoding utf8
    Register-ManagedJobOwnerReference -Job ([pscustomobject]$staleRecord)
    @{ schemaVersion = 1; jobId = $staleId; hostPid = 2147483647; wtSession = [guid]::NewGuid(); wtComClsid = [guid]::NewGuid() } |
        ConvertTo-Json | Set-Content -LiteralPath (Get-ManagedJobControlFile -Id $staleId) -Encoding utf8
    $startPayload = [ordered]@{
        hook_event_name = 'SessionStart'; session_id = $sessionId; cwd = $testRoot; source = 'startup'
    } | ConvertTo-Json -Compress
    $startOutput = ($startPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $sessionStartHook -ManagedHookId managed-jobs-session-start 2>&1 | Out-String)
    Assert-True ([string]::IsNullOrWhiteSpace($startOutput)) 'SessionStart should silently reconcile in its background handler.'
    Assert-True (-not (Test-Path -LiteralPath (Get-ManagedJobControlFile -Id $staleId))) `
        'Hook-scheduled reconciliation should remove stale shared-terminal control metadata.'
    Assert-True (@(Get-ManagedJobOwnerReferenceIds -OwnerAgent claude -OwnerSessionId $sessionId -Lifetime turn) -notcontains $staleId) `
        'Hook-scheduled reconciliation should remove stale owner references.'

    $heldMaintenanceLock = [IO.File]::Open((Join-Path $stateRoot '.maintenance.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $queuedHook = Start-SessionStartHookProcess -Payload $startPayload
        Start-Sleep -Milliseconds 500
        Assert-True (-not $queuedHook.process.HasExited) `
            'SessionStart reconciliation should wait when another maintenance operation holds the lock.'
    } finally {
        $heldMaintenanceLock.Dispose()
    }
    if (-not $queuedHook.process.WaitForExit(10000)) {
        try { $queuedHook.process.Kill($true) } catch {}
        throw 'Queued SessionStart reconciliation did not finish after the maintenance lock was released.'
    }
    $queuedOutput = $queuedHook.outputTask.GetAwaiter().GetResult()
    $queuedError = $queuedHook.errorTask.GetAwaiter().GetResult()
    Assert-True ($queuedHook.process.ExitCode -eq 0 -and
        [string]::IsNullOrWhiteSpace($queuedOutput) -and
        [string]::IsNullOrWhiteSpace($queuedError)) `
        'Queued SessionStart reconciliation should finish silently after the maintenance lock is released.'
    $queuedHook.process.Dispose()

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
    Assert-True ($backgroundDecision.hookSpecificOutput.permissionDecisionReason -match 'foreground') 'The deny reason should rule out the foreground-with-timeout fallback.'
    $detachedPayload = [ordered]@{
        hook_event_name = 'PreToolUse'; tool_name = 'PowerShell'
        tool_input = [ordered]@{ command = "Start-Process pwsh -ArgumentList '-File','engine.ps1'" }
    } | ConvertTo-Json -Compress
    $detachedDecision = ($detachedPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $launchGuard | Out-String) | ConvertFrom-Json
    Assert-True ($detachedDecision.hookSpecificOutput.permissionDecision -eq 'deny') 'The launch guard should deny a bare Start-Process detach, which opens an unmanaged console window.'
    $allowedDetachPayload = [ordered]@{
        hook_event_name = 'PreToolUse'; tool_name = 'PowerShell'
        tool_input = [ordered]@{ command = "Start-Process notepad # managed-jobs: allow-direct" }
    } | ConvertTo-Json -Compress
    $allowedDetachOutput = ($allowedDetachPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $launchGuard | Out-String)
    Assert-True ([string]::IsNullOrWhiteSpace($allowedDetachOutput)) 'The explicit allow-direct marker should still bypass the launch guard.'
    $compoundPayload = [ordered]@{
        hook_event_name = 'PreToolUse'; tool_name = 'PowerShell'
        tool_input = [ordered]@{ command = "& 'skills/managed-jobs/scripts/Invoke-ManagedJob.ps1' list; Start-Process pwsh" }
    } | ConvertTo-Json -Compress
    $compoundDecision = ($compoundPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $launchGuard | Out-String) | ConvertFrom-Json
    Assert-True ($compoundDecision.hookSpecificOutput.permissionDecision -eq 'deny') 'A controller mention must not exempt a compound command that also detaches directly.'
    $controllerPayload = [ordered]@{
        hook_event_name = 'PreToolUse'; tool_name = 'PowerShell'
        tool_input = [ordered]@{ command = "& 'skills/managed-jobs/scripts/Invoke-ManagedJob.ps1' start -Name api -Executable dotnet" }
    } | ConvertTo-Json -Compress
    $controllerOutput = ($controllerPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $launchGuard | Out-String)
    Assert-True ([string]::IsNullOrWhiteSpace($controllerOutput)) 'A pure controller invocation should stay exempt from the launch guard.'
    $retryPayload = [ordered]@{
        hook_event_name = 'PreToolUse'; tool_name = 'Bash'
        tool_input = [ordered]@{ command = 'python -m http.server' }
    } | ConvertTo-Json -Compress
    $retryDecision = ($retryPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $launchGuard | Out-String) | ConvertFrom-Json
    Assert-True ($retryDecision.hookSpecificOutput.permissionDecision -eq 'deny') 'A foreground retry of a recently denied launch should be denied.'
    Assert-True ($retryDecision.hookSpecificOutput.permissionDecisionReason -match 'recently denied') 'The retry denial should explain that the command was recently denied.'
    $controllerBackgroundPayload = [ordered]@{
        hook_event_name = 'PreToolUse'; tool_name = 'Bash'
        tool_input = [ordered]@{ command = "pwsh -File 'skills/managed-jobs/scripts/Invoke-ManagedJob.ps1' list; python -m other.server"; run_in_background = $true }
    } | ConvertTo-Json -Compress
    $controllerBackgroundDecision = ($controllerBackgroundPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $launchGuard | Out-String) | ConvertFrom-Json
    Assert-True ($controllerBackgroundDecision.hookSpecificOutput.permissionDecision -eq 'deny') 'A controller mention must not exempt a natively backgrounded tool call.'
    $guardCacheFile = Join-Path $stateRoot 'guard\denied-launches.json'
    Set-Content -LiteralPath $guardCacheFile -Value '{not valid json' -Encoding utf8
    $corruptCacheDecision = ($detachedPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $launchGuard | Out-String) | ConvertFrom-Json
    Assert-True ($corruptCacheDecision.hookSpecificOutput.permissionDecision -eq 'deny') 'A corrupt retry cache must not disable pattern-based denials.'
    $env:MANAGED_JOBS_ROOT = 'NoSuchDrive:\managed-jobs-state'
    $unavailableRootDecision = ($detachedPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $launchGuard | Out-String) | ConvertFrom-Json
    Assert-True ($unavailableRootDecision.hookSpecificOutput.permissionDecision -eq 'deny') 'An unavailable state-root drive must not disable pattern-based denials.'
    $env:MANAGED_JOBS_ROOT = $stateRoot
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
