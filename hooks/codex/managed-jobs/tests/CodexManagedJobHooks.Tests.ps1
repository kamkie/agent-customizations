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
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-managed-job-hooks-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $testRoot 'state'
$activeIds = [Collections.Generic.List[string]]::new()
$assertionCount = 0
$previousCodexHome = $env:CODEX_HOME
$previousThreadId = $env:CODEX_THREAD_ID
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
    $sessionId = 'codex-hook-session'
    $env:CODEX_HOME = $repositoryRoot
    $env:CODEX_THREAD_ID = $sessionId
    $env:MANAGED_JOBS_ROOT = $stateRoot
    . $common
    Set-ManagedJobStateRoot -Path $stateRoot
    $null = Get-ManagedJobRoot

    $staleId = '20000101-000000-hook-stale-completed-000001'
    $staleRecord = [ordered]@{
        schemaVersion = 4; id = $staleId; name = 'hook-stale-completed'; kind = 'test'; status = 'completed'
        lifetime = 'turn'; ownerAgent = 'codex'; ownerSessionId = $sessionId; visible = $true; sharedTerminal = $true
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
    Assert-True (@(Get-ManagedJobOwnerReferenceIds -OwnerAgent codex -OwnerSessionId $sessionId -Lifetime turn) -notcontains $staleId) `
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
    $stopPayload = [ordered]@{
        hook_event_name = 'Stop'; session_id = $sessionId; turn_id = 'turn-1'; cwd = $testRoot; stop_hook_active = $false
    } | ConvertTo-Json -Compress
    $stopOutput = ('' | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook -ManagedHookId managed-jobs-stop | Out-String)
    Assert-True ([string]::IsNullOrWhiteSpace($stopOutput)) 'Successful Stop cleanup should use the environment when stdin is empty and emit no context.'
    $activeIds.Remove($turnJob.id) | Out-Null
    Assert-True ((Get-JobStatus -Id $turnJob.id).status -eq 'stopped') 'The Stop hook should terminate a turn-owned process tree.'

    $sessionJobs = @(
        foreach ($index in 1..4) {
            $sessionJob = (& $controller start -StateRoot $stateRoot -Name "hook-session-owned-$index" -Executable $pwsh `
                -Arguments @('-NoProfile', '-Command', "Write-Output session-$index; Start-Sleep -Seconds 30") -Lifetime Session | Out-String) | ConvertFrom-Json
            $activeIds.Add($sessionJob.id)
            Wait-JobRunning -Id $sessionJob.id
        }
    )
    $sessionPayload = [ordered]@{ hook_event_name = 'SessionEnd'; session_id = $sessionId; cwd = $testRoot } | ConvertTo-Json -Compress
    $sessionTimer = [Diagnostics.Stopwatch]::StartNew()
    $sessionOutput = ('' | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $sessionEndHook -ManagedHookId managed-jobs-session-end 2>&1 | Out-String)
    $sessionTimer.Stop()
    Assert-True ([string]::IsNullOrWhiteSpace($sessionOutput)) 'Successful SessionEnd cleanup should use the environment when stdin is empty and emit no context.'
    Assert-True ($sessionTimer.Elapsed.TotalSeconds -lt 3) 'SessionEnd should clean several owned jobs within the Codex three-second limit.'
    foreach ($sessionJob in $sessionJobs) {
        $activeIds.Remove($sessionJob.id) | Out-Null
        Assert-True ((Get-JobStatus -Id $sessionJob.id).status -eq 'stopped') 'The SessionEnd hook should terminate every session-owned process tree.'
    }

    $unclaimedId = '20000101-000000-hook-owned-starting-000001'
    $unclaimedRecord = [ordered]@{
        schemaVersion = 3; id = $unclaimedId; name = 'hook-owned-starting'; kind = 'test'; status = 'starting'
        lifetime = 'turn'; ownerAgent = 'codex'; ownerSessionId = $sessionId; visible = $false; keepTerminalOpen = $false
        processContainment = 'pending'; createdAtUtc = [datetime]::UtcNow.ToString('o'); startedAtUtc = $null; finishedAtUtc = $null
        hostPid = $null; hostStartedAtUtc = $null; executable = 'fixture'; argumentCount = 0; environmentNames = @()
        invocationFingerprint = ('5' * 64); workingDirectory = $testRoot; logPath = (Join-Path $stateRoot "logs\$unclaimedId.log")
        exitCode = $null; error = $null
    }
    $unclaimedRecord | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot "jobs\$unclaimedId.json") -Encoding utf8
    Register-ManagedJobOwnerReference -Job ([pscustomobject]$unclaimedRecord)
    $blockedOutput = ($stopPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook | Out-String) | ConvertFrom-Json
    Assert-True ($blockedOutput.decision -eq 'block') 'Stop cleanup should ask Codex to continue when an owned process cannot be verified.'
    Assert-True ($blockedOutput.reason -match 'hook-owned-starting') 'Blocked cleanup should clearly name the affected job.'
    Assert-True ($blockedOutput.PSObject.Properties.Name -notcontains 'continue') 'Stop cleanup must not suppress its own continuation decision.'
    $continuedPayload = [ordered]@{
        hook_event_name = 'Stop'; session_id = $sessionId; turn_id = 'turn-1'; cwd = $testRoot; stop_hook_active = $true
    } | ConvertTo-Json -Compress
    $boundedOutput = ($continuedPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook | Out-String) | ConvertFrom-Json
    Assert-True ($boundedOutput.systemMessage -match 'will not block the turn again') 'A repeated cleanup failure should warn without creating a Stop-hook loop.'
    Assert-True ($boundedOutput.PSObject.Properties.Name -notcontains 'decision') 'A repeated cleanup failure should allow the turn to end.'
    Unregister-ManagedJobOwnerReference -Job ([pscustomobject]$unclaimedRecord)
    Remove-Item -LiteralPath (Join-Path $stateRoot "jobs\$unclaimedId.json") -Force

    $env:CODEX_HOME = Join-Path $testRoot 'missing-codex-home'
    $infrastructureFirst = ($stopPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook | Out-String) | ConvertFrom-Json
    Assert-True ($infrastructureFirst.decision -eq 'block') 'The first hook infrastructure failure should give Codex one chance to recover.'
    $infrastructureBounded = ($continuedPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook | Out-String) | ConvertFrom-Json
    Assert-True ($infrastructureBounded.systemMessage -match 'will not block the turn again') 'A repeated hook infrastructure failure should degrade to one clear warning.'
    Assert-True ($infrastructureBounded.PSObject.Properties.Name -notcontains 'decision') 'A repeated infrastructure failure must not wedge the turn.'
    $env:CODEX_HOME = $repositoryRoot

    Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
    $payloadStopOutput = ($stopPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $stopHook | Out-String)
    Assert-True ([string]::IsNullOrWhiteSpace($payloadStopOutput)) 'Stop cleanup should use payload.session_id when CODEX_THREAD_ID is absent.'
    $payloadSessionOutput = ($sessionPayload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $sessionEndHook 2>&1 | Out-String)
    Assert-True ([string]::IsNullOrWhiteSpace($payloadSessionOutput)) 'SessionEnd cleanup should use payload.session_id when CODEX_THREAD_ID is absent.'
    $env:CODEX_THREAD_ID = $sessionId

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
        (Split-Path -Leaf $testRoot) -like 'codex-managed-job-hooks-*') {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($entry in @(
        @{ Name = 'CODEX_HOME'; Value = $previousCodexHome },
        @{ Name = 'CODEX_THREAD_ID'; Value = $previousThreadId },
        @{ Name = 'MANAGED_JOBS_ROOT'; Value = $previousStateRoot }
    )) {
        if ($null -eq $entry.Value) {
            Remove-Item "Env:$($entry.Name)" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($entry.Name, [string]$entry.Value, 'Process')
        }
    }
}
