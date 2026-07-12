param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('start', 'list', 'status', 'logs', 'stop', 'reconcile', 'prune')]
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
    [int]$Tail = 100,
    [switch]$Follow,
    [int]$OlderThanDays = 14
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ManagedJob.Common.ps1')

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
    if ($Job.status -notin @('starting', 'running')) { return $Job }
    if (Test-ManagedProcessIdentity -ProcessId $Job.hostPid -ExpectedStartTimeUtc $Job.hostStartedAtUtc) { return $Job }
    $path = Get-ManagedJobFile -Id $Job.id
    $Job.status = 'orphaned'
    $Job.finishedAtUtc = [datetime]::UtcNow.ToString('o')
    $Job.error = 'Recorded host process is no longer running and no terminal state was recorded.'
    Write-ManagedJob -Path $path -Job $Job
    return $Job
}

switch ($Action) {
    'start' {
        if (-not $Name) { throw '-Name is required for start.' }
        if (-not $Executable) { throw '-Executable is required for start.' }
        $resolvedDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
        $slug = ConvertTo-SafeJobName -Name $Name
        $jobId = '{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $slug, ([guid]::NewGuid().ToString('N').Substring(0, 6))
        $root = Get-ManagedJobRoot
        $jobFile = Get-ManagedJobFile -Id $jobId
        $logPath = Join-Path (Join-Path $root 'logs') "$jobId.log"
        $environmentObject = [ordered]@{}
        foreach ($key in $Environment.Keys) { $environmentObject[[string]$key] = [string]$Environment[$key] }
        $job = [ordered]@{
            schemaVersion = 1
            id = $jobId
            name = $Name
            kind = $Kind
            status = 'starting'
            visible = [bool]$Visible
            keepTerminalOpen = [bool]$KeepTerminalOpen
            createdAtUtc = [datetime]::UtcNow.ToString('o')
            startedAtUtc = $null
            finishedAtUtc = $null
            hostPid = $null
            hostStartedAtUtc = $null
            executable = $Executable
            arguments = @($Arguments)
            workingDirectory = $resolvedDirectory
            environment = $environmentObject
            logPath = $logPath
            exitCode = $null
            error = $null
        }
        Write-ManagedJob -Path $jobFile -Job $job
        $hostScript = Join-Path $PSScriptRoot 'ManagedJob.Host.ps1'

        if ($Visible) {
            $wt = Get-Command wt.exe -ErrorAction Stop
            $pwshArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
            if ($KeepTerminalOpen) { $pwshArguments += '-NoExit' }
            $pwshArguments += @('-File', $hostScript, '-JobFile', $jobFile)
            $terminalArguments = @('-w', 'codex-managed-jobs', 'new-tab', '--title', $Name, 'pwsh.exe') + $pwshArguments
            Start-Process -FilePath $wt.Source -ArgumentList $terminalArguments -WindowStyle Hidden | Out-Null
        } else {
            $hostArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $hostScript + '"'), '-JobFile', ('"' + $jobFile + '"'))
            Start-Process -FilePath 'pwsh.exe' -ArgumentList $hostArguments -WindowStyle Hidden | Out-Null
        }

        $deadline = [datetime]::UtcNow.AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 100
            $job = Read-ManagedJob -Path $jobFile
        } while ($job.status -eq 'starting' -and [datetime]::UtcNow -lt $deadline)
        $job | ConvertTo-Json -Depth 10
    }
    'list' {
        Get-AllManagedJobs | ForEach-Object { Update-ReconciledJob -Job $_ } |
            Sort-Object createdAtUtc -Descending |
            Select-Object id, name, kind, status, visible, hostPid, createdAtUtc, finishedAtUtc, logPath |
            Format-Table -AutoSize
    }
    'status' {
        if (-not $Id) { throw '-Id is required for status.' }
        $job = Read-ManagedJob -Path (Get-ManagedJobFile -Id $Id)
        Update-ReconciledJob -Job $job | ConvertTo-Json -Depth 10
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
        if (-not (Test-ManagedProcessIdentity -ProcessId $job.hostPid -ExpectedStartTimeUtc $job.hostStartedAtUtc)) {
            $job = Update-ReconciledJob -Job $job
            throw "Refusing to stop PID $($job.hostPid): its identity no longer matches the registry. Job marked $($job.status)."
        }
        & taskkill.exe /PID $job.hostPid /T /F | Out-Null
        $job = Read-ManagedJob -Path $path
        $job.status = 'stopped'
        $job.finishedAtUtc = [datetime]::UtcNow.ToString('o')
        $job.exitCode = $null
        $job.error = 'Stopped through managed-jobs.'
        Write-ManagedJob -Path $path -Job $job
        $job | ConvertTo-Json -Depth 10
    }
    'reconcile' {
        $jobs = @(Get-AllManagedJobs | ForEach-Object { Update-ReconciledJob -Job $_ })
        $summary = [ordered]@{
            total = $jobs.Count
            running = @($jobs | Where-Object status -eq 'running').Count
            starting = @($jobs | Where-Object status -eq 'starting').Count
            completed = @($jobs | Where-Object status -eq 'completed').Count
            failed = @($jobs | Where-Object status -eq 'failed').Count
            stopped = @($jobs | Where-Object status -eq 'stopped').Count
            orphaned = @($jobs | Where-Object status -eq 'orphaned').Count
            active = @($jobs | Where-Object status -in @('starting', 'running') | Select-Object id, name, kind, status, visible, logPath)
        }
        $summary | ConvertTo-Json -Depth 10
    }
    'prune' {
        $cutoff = [datetime]::UtcNow.AddDays(-[math]::Abs($OlderThanDays))
        $removed = @()
        foreach ($job in Get-AllManagedJobs) {
            if ($job.status -in @('starting', 'running')) { continue }
            $timestampText = if ($job.finishedAtUtc) { $job.finishedAtUtc } else { $job.createdAtUtc }
            $timestamp = if ($timestampText -is [datetime]) { $timestampText.ToUniversalTime() } else { [datetimeoffset]::Parse([string]$timestampText).UtcDateTime }
            if ($timestamp -ge $cutoff) { continue }
            $record = Get-ManagedJobFile -Id $job.id
            if ($job.logPath -and (Test-Path -LiteralPath $job.logPath)) { Remove-Item -LiteralPath $job.logPath -Force }
            Remove-Item -LiteralPath $record -Force
            $removed += $job.id
        }
        [pscustomobject]@{ removedCount = $removed.Count; removed = $removed } | ConvertTo-Json -Depth 5
    }
}
