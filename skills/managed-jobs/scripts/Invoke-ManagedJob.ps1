[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('start', 'list', 'status', 'logs', 'stop', 'cleanup', 'reconcile', 'prune')]
    [string]$Action,

    [string]$Id,
    [string]$Name,
    [string]$Kind = 'generic',
    [string]$Executable,
    [string[]]$Arguments = @(),
    [string]$WorkingDirectory = (Get-Location).Path,
    [hashtable]$Environment = @{},
    [switch]$Visible,
    [switch]$KeepTerminalOpen,
    [ValidateSet('Auto', 'Turn', 'Session', 'Persistent')]
    [string]$Lifetime = 'Auto',
    [ValidateSet('Turn', 'Session')]
    [string[]]$CleanupLifetime = @('Turn'),
    [string]$OwnerAgent,
    [string]$OwnerSessionId,
    [int]$Tail = 100,
    [switch]$Follow,
    [int]$OlderThanDays = 14,
    [string]$StateRoot,
    [ValidateSet('starting', 'running', 'completed', 'failed', 'stopped', 'orphaned', 'invalid')]
    [string[]]$Status,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ManagedJob.Common.ps1')
$automaticCleanupRoot = Get-ManagedJobAutomaticCleanupRoot
Set-ManagedJobStateRoot -Path $StateRoot
$managedJobHome = [IO.Path]::GetFullPath(
    (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
)
$codexHome = if ($env:CODEX_HOME) {
    [IO.Path]::GetFullPath($env:CODEX_HOME)
} else {
    [IO.Path]::GetFullPath((Join-Path $HOME '.codex'))
}
$isCodexInstallation = $managedJobHome.Equals($codexHome, [StringComparison]::OrdinalIgnoreCase)

function Get-AllManagedJobs {
    $jobsDirectory = Join-Path (Get-ManagedJobRoot) 'jobs'
    foreach ($file in Get-ChildItem -LiteralPath $jobsDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try { Read-ManagedJob -Path $file.FullName } catch {
            [pscustomobject]@{ id = $file.BaseName; status = 'invalid'; error = $_.Exception.Message; recordPath = $file.FullName }
        }
    }
}

function Update-ReconciledJob {
    param($Job)
    if ($Job.status -notin @('starting', 'running')) {
        try { Unregister-ManagedJobOwnerReference -Job $Job } catch {}
        return $Job
    }
    if ($Job.status -eq 'starting' -and -not $Job.hostPid) {
        $createdAt = if ($Job.createdAtUtc -is [datetime]) {
            $Job.createdAtUtc.ToUniversalTime()
        } else {
            [datetimeoffset]::Parse([string]$Job.createdAtUtc).UtcDateTime
        }
        if (([datetime]::UtcNow - $createdAt).TotalSeconds -lt 30) { return $Job }
    }
    if (Test-ManagedProcessIdentity -ProcessId $Job.hostPid -ExpectedStartTimeUtc $Job.hostStartedAtUtc) { return $Job }
    $path = Get-ManagedJobFile -Id $Job.id
    $current = Read-ManagedJob -Path $path
    if ($current.status -notin @('starting', 'running')) {
        try { Unregister-ManagedJobOwnerReference -Job $current } catch {}
        return $current
    }
    if ($current.status -eq 'starting' -and -not $current.hostPid) {
        $createdAt = if ($current.createdAtUtc -is [datetime]) {
            $current.createdAtUtc.ToUniversalTime()
        } else {
            [datetimeoffset]::Parse([string]$current.createdAtUtc).UtcDateTime
        }
        if (([datetime]::UtcNow - $createdAt).TotalSeconds -lt 30) { return $current }
    }
    if (Test-ManagedProcessIdentity -ProcessId $current.hostPid -ExpectedStartTimeUtc $current.hostStartedAtUtc) { return $current }
    $current.status = 'orphaned'
    $current.finishedAtUtc = [datetime]::UtcNow.ToString('o')
    $current.error = 'Recorded host process is no longer running and no terminal state was recorded.'
    Write-ManagedJob -Path $path -Job $current
    Unregister-ManagedJobOwnerReference -Job $current
    $unclaimedLaunch = Join-Path (Join-Path (Get-ManagedJobRoot) 'launch') "$($Job.id).json"
    if (Test-Path -LiteralPath $unclaimedLaunch) { Remove-Item -LiteralPath $unclaimedLaunch -Force }
    return $current
}

function Select-ManagedJobs {
    param([object[]]$Jobs)
    if ($Status) { return @($Jobs | Where-Object { $_.status -in $Status }) }
    return @($Jobs)
}

function Add-ManagedJobIdentity {
    param($Job)
    $copy = [ordered]@{}
    foreach ($property in $Job.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    if (($Job.PSObject.Properties.Name -contains 'hostPid') -and $Job.status -in @('starting', 'running', 'orphaned')) {
        $copy.processIdentity = Get-ManagedProcessIdentity -Job $Job
    }
    return [pscustomobject]$copy
}

function Write-JobCollection {
    param([object[]]$Jobs)
    $output = @(foreach ($job in @($Jobs)) {
        if ($null -ne $job) { Add-ManagedJobIdentity -Job $job }
    })
    if ($Json) {
        ConvertTo-Json -InputObject $output -Depth 12
    } else {
        $output | Select-Object id, name, kind, status, lifetime, visible, hostPid, createdAtUtc, finishedAtUtc, logPath | Format-Table -AutoSize
    }
}

function Stop-ManagedJobTree {
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][string]$Reason
    )

    $path = Get-ManagedJobFile -Id $Job.id
    $current = Read-ManagedJob -Path $path
    if ($current.status -notin @('starting', 'running')) { return $current }
    if (-not (Test-ManagedProcessIdentity -ProcessId $current.hostPid -ExpectedStartTimeUtc $current.hostStartedAtUtc)) {
        $current = Update-ReconciledJob -Job $current
        if ($current.status -notin @('starting', 'running')) { return $current }
        throw "Job $($current.id) has not published a verifiable host process yet."
    }

    $taskkillOutput = @(& taskkill.exe /PID $current.hostPid /T /F 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $current = Update-ReconciledJob -Job (Read-ManagedJob -Path $path)
        if ($current.status -notin @('starting', 'running')) { return $current }
        throw "Unable to terminate PID $($current.hostPid): $($taskkillOutput -join ' ')"
    }

    $current = Read-ManagedJob -Path $path
    if ($current.status -in @('starting', 'running')) {
        $current.status = 'stopped'
        $current.finishedAtUtc = [datetime]::UtcNow.ToString('o')
        $current.exitCode = $null
        $current.error = $Reason
        Write-ManagedJob -Path $path -Job $current
    }
    Unregister-ManagedJobOwnerReference -Job $current
    return $current
}

switch ($Action) {
    'start' {
        if (-not $Name) { throw '-Name is required for start.' }
        if (-not $Executable) { throw '-Executable is required for start.' }
        if ($KeepTerminalOpen -and -not $Visible) { throw '-KeepTerminalOpen requires -Visible.' }
        Assert-SecretSafeInvocation -Arguments $Arguments -Environment $Environment
        $resolvedOwnerAgent = if ($OwnerAgent) {
            $OwnerAgent.Trim().ToLowerInvariant()
        } elseif ($isCodexInstallation -and $env:CODEX_THREAD_ID) {
            'codex'
        } else {
            $null
        }
        $resolvedOwnerSessionId = if ($OwnerSessionId) {
            $OwnerSessionId.Trim()
        } elseif ($isCodexInstallation -and $env:CODEX_THREAD_ID) {
            $env:CODEX_THREAD_ID.Trim()
        } else {
            $null
        }
        $resolvedLifetime = if ($Lifetime -eq 'Auto') {
            if ($resolvedOwnerAgent -and $resolvedOwnerSessionId) { 'turn' } else { 'persistent' }
        } else {
            $Lifetime.ToLowerInvariant()
        }
        if ($resolvedLifetime -in @('turn', 'session') -and
            (-not $resolvedOwnerAgent -or -not $resolvedOwnerSessionId)) {
            throw "Lifetime '$Lifetime' requires -OwnerAgent and -OwnerSessionId, or a Codex invocation with CODEX_THREAD_ID."
        }
        $resolvedRoot = [IO.Path]::GetFullPath((Get-ManagedJobRoot))
        if ($resolvedLifetime -in @('turn', 'session') -and
            -not $resolvedRoot.Equals($automaticCleanupRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Lifetime '$Lifetime' requires the hook-visible managed-job state root '$automaticCleanupRoot'. Set MANAGED_JOBS_ROOT before starting Codex instead of using a different -StateRoot, or use -Lifetime Persistent."
        }
        $resolvedDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
        $fingerprint = Get-InvocationFingerprint -Executable $Executable -Arguments $Arguments -WorkingDirectory $resolvedDirectory -Environment $Environment
        $root = Get-ManagedJobRoot
        $lockPath = Join-Path $root '.launch.lock'
        $lock = $null
        $launchFile = $null
        $jobFile = $null
        try {
            $deadline = [datetime]::UtcNow.AddSeconds(10)
            do {
                try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') } catch [IO.IOException] {
                    if ([datetime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the managed-jobs launch lock.' }
                    Start-Sleep -Milliseconds 100
                }
            } until ($lock)

            $active = @(Get-AllManagedJobs | ForEach-Object { Update-ReconciledJob -Job $_ } | Where-Object status -in @('starting', 'running'))
            $duplicate = $active | Where-Object {
                $_.PSObject.Properties.Name -contains 'invocationFingerprint' -and $_.invocationFingerprint -eq $fingerprint
            } | Select-Object -First 1
            if ($duplicate) {
                throw "Equivalent managed job is already active: $($duplicate.id) [$($duplicate.status)] $($duplicate.name)"
            }

            $slug = ConvertTo-SafeJobName -Name $Name
            $jobId = '{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $slug, ([guid]::NewGuid().ToString('N').Substring(0, 6))
            $jobFile = Get-ManagedJobFile -Id $jobId
            $logPath = Join-Path (Join-Path $root 'logs') "$jobId.log"
            $launchFile = Join-Path (Join-Path $root 'launch') "$jobId.json"
            $environmentObject = [ordered]@{}
            foreach ($key in $Environment.Keys) { $environmentObject[[string]$key] = [string]$Environment[$key] }
            $job = [ordered]@{
                schemaVersion = 3
                id = $jobId
                name = $Name
                kind = $Kind
                status = 'starting'
                lifetime = $resolvedLifetime
                ownerAgent = $resolvedOwnerAgent
                ownerSessionId = $resolvedOwnerSessionId
                visible = [bool]$Visible
                keepTerminalOpen = [bool]$KeepTerminalOpen
                processContainment = 'pending'
                createdAtUtc = [datetime]::UtcNow.ToString('o')
                startedAtUtc = $null
                finishedAtUtc = $null
                hostPid = $null
                hostStartedAtUtc = $null
                executable = $Executable
                argumentCount = @($Arguments).Count
                environmentNames = @($Environment.Keys | ForEach-Object { [string]$_ } | Sort-Object)
                invocationFingerprint = $fingerprint
                workingDirectory = $resolvedDirectory
                logPath = $logPath
                exitCode = $null
                error = $null
            }
            $launch = [ordered]@{
                executable = $Executable
                arguments = @($Arguments)
                environment = $environmentObject
            }
            Write-ManagedJob -Path $jobFile -Job $job
            Register-ManagedJobOwnerReference -Job ([pscustomobject]$job)
            Write-ManagedJson -Path $launchFile -Value $launch
            $hostScript = Join-Path $PSScriptRoot 'ManagedJob.Host.ps1'

            if ($Visible) {
                $wt = Get-Command wt.exe -ErrorAction Stop
                $pwshArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
                if ($KeepTerminalOpen) { $pwshArguments += '-NoExit' }
                $pwshArguments += @('-File', ('"' + $hostScript + '"'), '-JobFile', ('"' + $jobFile + '"'), '-LaunchFile', ('"' + $launchFile + '"'))
                $terminalArguments = @('-w', 'managed-jobs', 'new-tab', '--title', $Name, 'pwsh.exe') + $pwshArguments
                Start-Process -FilePath $wt.Source -ArgumentList $terminalArguments -WindowStyle Hidden | Out-Null
            } else {
                $hostArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $hostScript + '"'), '-JobFile', ('"' + $jobFile + '"'), '-LaunchFile', ('"' + $launchFile + '"'))
                Start-Process -FilePath 'pwsh.exe' -ArgumentList $hostArguments -WindowStyle Hidden | Out-Null
            }
        } catch {
            if ($launchFile -and (Test-Path -LiteralPath $launchFile)) { Remove-Item -LiteralPath $launchFile -Force -ErrorAction SilentlyContinue }
            if ($jobFile -and (Test-Path -LiteralPath $jobFile)) {
                try {
                    $failedJob = Read-ManagedJob -Path $jobFile
                    if ($failedJob.status -eq 'starting') {
                        $failedJob.status = 'failed'
                        $failedJob.finishedAtUtc = [datetime]::UtcNow.ToString('o')
                        $failedJob.error = 'Managed host launch failed before startup completed.'
                        Write-ManagedJob -Path $jobFile -Job $failedJob
                        Unregister-ManagedJobOwnerReference -Job $failedJob
                    }
                } catch {}
            }
            throw
        } finally {
            if ($lock) { $lock.Dispose() }
        }

        $startupDeadline = [datetime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 100
            $job = Read-ManagedJob -Path $jobFile
        } while ($job.status -eq 'starting' -and [datetime]::UtcNow -lt $startupDeadline)
        # A slow host may claim immediately after the final poll. Do not overwrite or
        # delete its launch handoff from a stale read; reconciliation owns the 30-second
        # unclaimed-start timeout and cleans the launch file when it marks an orphan.
        if ($job.status -eq 'starting') { $job = Read-ManagedJob -Path $jobFile }
        Add-ManagedJobIdentity -Job $job | ConvertTo-Json -Depth 12
    }
    'list' {
        $jobs = @(Get-AllManagedJobs | ForEach-Object { Update-ReconciledJob -Job $_ } | Sort-Object createdAtUtc -Descending)
        Write-JobCollection -Jobs (Select-ManagedJobs -Jobs $jobs)
    }
    'status' {
        if ($Id) {
            $job = Read-ManagedJob -Path (Get-ManagedJobFile -Id $Id)
            Add-ManagedJobIdentity -Job (Update-ReconciledJob -Job $job) | ConvertTo-Json -Depth 12
        } else {
            $jobs = @(Get-AllManagedJobs | ForEach-Object { Update-ReconciledJob -Job $_ } | Sort-Object createdAtUtc -Descending)
            Write-JobCollection -Jobs (Select-ManagedJobs -Jobs $jobs)
        }
    }
    'logs' {
        if (-not $Id) { throw '-Id is required for logs.' }
        $job = Read-ManagedJob -Path (Get-ManagedJobFile -Id $Id)
        if (-not (Test-Path -LiteralPath $job.logPath -PathType Leaf)) {
            throw "Log does not exist yet: $($job.logPath)"
        }
        Get-Content -LiteralPath $job.logPath -Tail $Tail -Wait:$Follow
    }
    'stop' {
        if (-not $Id) { throw '-Id is required for stop.' }
        $path = Get-ManagedJobFile -Id $Id
        $job = Read-ManagedJob -Path $path
        if ($job.status -notin @('starting', 'running')) {
            throw "Job $Id is not running; current status is $($job.status)."
        }
        $job = Stop-ManagedJobTree -Job $job -Reason 'Stopped through managed-jobs.'
        Add-ManagedJobIdentity -Job $job | ConvertTo-Json -Depth 12
    }
    'cleanup' {
        if (-not $OwnerAgent) { throw '-OwnerAgent is required for cleanup.' }
        if (-not $OwnerSessionId) { throw '-OwnerSessionId is required for cleanup.' }
        $ownerAgentKey = $OwnerAgent.Trim().ToLowerInvariant()
        $ownerSessionKey = $OwnerSessionId.Trim()
        $lifetimes = @($CleanupLifetime | ForEach-Object { $_.ToLowerInvariant() })
        $ownerIds = @(Get-ManagedJobOwnerReferenceIds `
            -OwnerAgent $ownerAgentKey `
            -OwnerSessionId $ownerSessionKey `
            -Lifetime $lifetimes |
            Sort-Object -Unique)
        $owned = @()
        $stopped = @()
        $failures = @()
        foreach ($ownerId in $ownerIds) {
            try {
                $job = Read-ManagedJob -Path (Get-ManagedJobFile -Id $ownerId)
                if ($job.PSObject.Properties.Name -notcontains 'ownerAgent' -or
                    $job.PSObject.Properties.Name -notcontains 'ownerSessionId' -or
                    $job.PSObject.Properties.Name -notcontains 'lifetime' -or
                    [string]$job.ownerAgent -ne $ownerAgentKey -or
                    [string]$job.ownerSessionId -ne $ownerSessionKey -or
                    [string]$job.lifetime -notin $lifetimes) {
                    throw 'The ownership reference does not match the managed-job record.'
                }
                $job = Update-ReconciledJob -Job $job
                if ($job.status -notin @('starting', 'running')) {
                    Unregister-ManagedJobOwnerReference -Job $job
                    continue
                }
                if (-not (Test-ManagedProcessIdentity -ProcessId $job.hostPid -ExpectedStartTimeUtc $job.hostStartedAtUtc)) {
                    throw "Job $($job.id) has not published a verifiable host process yet."
                }
                if ([string]$job.processContainment -ne 'windows-job-object-kill-on-close') {
                    throw "Job $($job.id) has not confirmed Windows process-tree containment."
                }
                $owned += $job
            } catch {
                $failures += [ordered]@{
                    id = $ownerId
                    name = $ownerId
                    hostPid = $null
                    lifetime = $null
                    error = $_.Exception.Message
                }
            }
        }
        $stopError = $null
        if ($owned.Count -gt 0) {
            $stopErrors = @()
            Stop-Process `
                -Id @($owned | ForEach-Object { [int]$_.hostPid }) `
                -Force `
                -ErrorAction SilentlyContinue `
                -ErrorVariable +stopErrors
            if ($stopErrors.Count -gt 0) {
                $stopError = @($stopErrors | ForEach-Object { $_.Exception.Message }) -join ' | '
            }

            $stopDeadline = [datetime]::UtcNow.AddSeconds(1)
            do {
                $stillRunning = @($owned | Where-Object {
                    Test-ManagedProcessIdentity -ProcessId $_.hostPid -ExpectedStartTimeUtc $_.hostStartedAtUtc
                })
                if ($stillRunning.Count -eq 0 -or [datetime]::UtcNow -ge $stopDeadline) { break }
                Start-Sleep -Milliseconds 25
            } while ($true)
        }
        foreach ($job in $owned) {
            try {
                if (Test-ManagedProcessIdentity -ProcessId $job.hostPid -ExpectedStartTimeUtc $job.hostStartedAtUtc) {
                    $detail = if ($stopError) { ": $stopError" } else { '' }
                    throw "Unable to terminate PID $($job.hostPid)$detail"
                }
                $path = Get-ManagedJobFile -Id $job.id
                $result = Read-ManagedJob -Path $path
                if ($result.status -in @('starting', 'running')) {
                    $result.status = 'stopped'
                    $result.finishedAtUtc = [datetime]::UtcNow.ToString('o')
                    $result.exitCode = $null
                    $result.error = "Stopped automatically at the end of its $($result.lifetime) lifetime."
                    Write-ManagedJob -Path $path -Job $result
                }
                Unregister-ManagedJobOwnerReference -Job $result
                if ($result.status -eq 'stopped') {
                    $stopped += [ordered]@{
                        id = $result.id
                        name = $result.name
                        hostPid = $result.hostPid
                        lifetime = $result.lifetime
                    }
                }
            } catch {
                $failures += [ordered]@{
                    id = $job.id
                    name = $job.name
                    hostPid = $job.hostPid
                    lifetime = $job.lifetime
                    error = $_.Exception.Message
                }
            }
        }
        [ordered]@{
            ownerAgent = $ownerAgentKey
            ownerSessionId = $ownerSessionKey
            lifetimes = $lifetimes
            matched = $owned.Count
            stopped = $stopped
            failures = $failures
        } | ConvertTo-Json -Depth 8
    }
    'reconcile' {
        $jobs = @(Get-AllManagedJobs | ForEach-Object { Update-ReconciledJob -Job $_ })
        $selected = Select-ManagedJobs -Jobs $jobs
        $summary = [ordered]@{
            stateRoot = Get-ManagedJobRoot
            total = $jobs.Count
            running = @($jobs | Where-Object status -eq 'running').Count
            starting = @($jobs | Where-Object status -eq 'starting').Count
            completed = @($jobs | Where-Object status -eq 'completed').Count
            failed = @($jobs | Where-Object status -eq 'failed').Count
            stopped = @($jobs | Where-Object status -eq 'stopped').Count
            orphaned = @($jobs | Where-Object status -eq 'orphaned').Count
            selectedStatuses = @($Status)
            jobs = @($selected | ForEach-Object { Add-ManagedJobIdentity -Job $_ })
            active = @($jobs | Where-Object status -in @('starting', 'running') | Select-Object id, name, kind, status, visible, logPath)
        }
        $summary | ConvertTo-Json -Depth 12
    }
    'prune' {
        $cutoff = [datetime]::UtcNow.AddDays(-[math]::Abs($OlderThanDays))
        $candidates = @()
        $removed = @()
        foreach ($job in Get-AllManagedJobs) {
            if ($job.status -in @('starting', 'running', 'invalid')) { continue }
            if ($Status -and $job.status -notin $Status) { continue }
            $timestampText = if ($job.finishedAtUtc) { $job.finishedAtUtc } else { $job.createdAtUtc }
            $timestamp = if ($timestampText -is [datetime]) { $timestampText.ToUniversalTime() } else { [datetimeoffset]::Parse([string]$timestampText).UtcDateTime }
            if ($timestamp -ge $cutoff) { continue }
            $candidates += $job.id
            if ($PSCmdlet.ShouldProcess($job.id, 'Remove terminal managed-job record and its managed log')) {
                try { Unregister-ManagedJobOwnerReference -Job $job } catch {}
                $record = Get-ManagedJobFile -Id $job.id
                $managedLog = Join-Path (Join-Path (Get-ManagedJobRoot) 'logs') "$($job.id).log"
                if (Test-Path -LiteralPath $managedLog) { Remove-Item -LiteralPath $managedLog -Force }
                Remove-Item -LiteralPath $record -Force
                $removed += $job.id
            }
        }
        [pscustomobject]@{ cutoffUtc = $cutoff.ToString('o'); candidateCount = $candidates.Count; candidates = $candidates; removedCount = $removed.Count; removed = $removed; preview = [bool]$WhatIfPreference } | ConvertTo-Json -Depth 5
    }
}
