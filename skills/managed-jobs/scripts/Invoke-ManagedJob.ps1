[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('start', 'list', 'status', 'wait-ready', 'logs', 'capture', 'send-input', 'send-key', 'stop', 'cleanup', 'reconcile', 'prune')]
    [string]$Action,

    [string]$Id,
    [string]$Name,
    [string]$Kind = 'generic',
    [string]$Executable,
    [string[]]$Arguments = @(),
    [string]$WorkingDirectory = (Get-Location).Path,
    [hashtable]$Environment = @{},
    [switch]$Visible,
    [switch]$SharedTerminal,
    [switch]$RequireBackgroundTab,
    [switch]$KeepTerminalOpen,
    [ValidateSet('Auto', 'Turn', 'Session', 'Persistent')]
    [string]$Lifetime = 'Auto',
    [ValidateSet('Turn', 'Session')]
    [string[]]$CleanupLifetime = @('Turn'),
    [string]$OwnerAgent,
    [string]$OwnerSessionId,
    [uri]$ReadinessUri,
    [ValidateRange(1, 600)]
    [int]$ReadinessTimeoutSeconds = 30,
    [int]$Tail = 100,
    [switch]$Follow,
    [AllowEmptyString()]
    [string]$InputText,
    [ValidateSet('Enter', 'Tab', 'Escape', 'Backspace', 'Ctrl+C')]
    [string[]]$Key,
    [ValidateRange(1, 500)]
    [int]$MaxLines = 100,
    [int]$OlderThanDays = 14,
    [switch]$Async,
    [string]$MaintenancePlan,
    [switch]$WaitForMaintenanceLock,
    [ValidateRange(1, 3600)][int]$MaintenanceLockWaitSeconds = 300,
    [string]$StateRoot,
    [ValidateSet('starting', 'running', 'completed', 'failed', 'stopped', 'orphaned', 'invalid')]
    [string[]]$Status,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$readinessParametersUsed = $PSBoundParameters.ContainsKey('ReadinessUri') -or
    $PSBoundParameters.ContainsKey('ReadinessTimeoutSeconds')
if ($Action -notin @('start', 'wait-ready') -and $readinessParametersUsed) {
    throw '-ReadinessUri and -ReadinessTimeoutSeconds are valid only for start and wait-ready.'
}
if ($Action -ne 'start' -and $PSBoundParameters.ContainsKey('SharedTerminal')) {
    throw '-SharedTerminal is valid only for start.'
}
if ($Action -ne 'start' -and $PSBoundParameters.ContainsKey('RequireBackgroundTab')) {
    throw '-RequireBackgroundTab is valid only for start.'
}
if ($Action -ne 'send-input' -and $PSBoundParameters.ContainsKey('InputText')) {
    throw '-InputText is valid only for send-input.'
}
if ($Action -ne 'send-key' -and $PSBoundParameters.ContainsKey('Key')) {
    throw '-Key is valid only for send-key.'
}
if ($Action -ne 'capture' -and $PSBoundParameters.ContainsKey('MaxLines')) {
    throw '-MaxLines is valid only for capture.'
}
if ($Action -notin @('reconcile', 'prune') -and $PSBoundParameters.ContainsKey('Async')) {
    throw '-Async is valid only for reconcile and prune.'
}
if ($Action -ne 'prune' -and $PSBoundParameters.ContainsKey('MaintenancePlan')) {
    throw '-MaintenancePlan is valid only for prune.'
}
if ($Async -and $PSBoundParameters.ContainsKey('MaintenancePlan')) {
    throw '-Async cannot be combined with -MaintenancePlan.'
}
if ($Action -ne 'reconcile' -and $PSBoundParameters.ContainsKey('WaitForMaintenanceLock')) {
    throw '-WaitForMaintenanceLock is valid only for reconcile.'
}
if ($Async -and $PSBoundParameters.ContainsKey('WaitForMaintenanceLock')) {
    throw '-Async cannot be combined with -WaitForMaintenanceLock.'
}
if (-not $WaitForMaintenanceLock -and $PSBoundParameters.ContainsKey('MaintenanceLockWaitSeconds')) {
    throw '-MaintenanceLockWaitSeconds requires -WaitForMaintenanceLock.'
}
if ($Async -and $WhatIfPreference) {
    throw '-Async cannot be combined with -WhatIf. Preview prune synchronously before scheduling it.'
}
. (Join-Path $PSScriptRoot 'ManagedJob.Common.ps1')
$automaticCleanupRoot = Get-ManagedJobAutomaticCleanupRoot
Set-ManagedJobStateRoot -Path $StateRoot
$managedJobHome = [IO.Path]::GetFullPath(
    (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
)
$codexHome = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($(
    if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
)))
$isCodexInstallation = $managedJobHome.Equals($codexHome, [StringComparison]::OrdinalIgnoreCase)
$claudeHome = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($(
    if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
)))
$isClaudeInstallation = $managedJobHome.Equals($claudeHome, [StringComparison]::OrdinalIgnoreCase)

function Get-AllManagedJobs {
    $jobsDirectory = Join-Path (Get-ManagedJobRoot) 'jobs'
    foreach ($file in Get-ChildItem -LiteralPath $jobsDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try { Read-ManagedJob -Path $file.FullName } catch {
            [pscustomobject]@{ id = $file.BaseName; status = 'invalid'; error = $_.Exception.Message; recordPath = $file.FullName }
        }
    }
}

function Remove-ManagedJobControl {
    param([Parameter(Mandatory)][string]$JobId)
    try {
        $controlFile = Get-ManagedJobControlFile -Id $JobId
        if (Test-Path -LiteralPath $controlFile -PathType Leaf) {
            Remove-Item -LiteralPath $controlFile -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Set-ManagedJobControlReleased {
    param([Parameter(Mandatory)]$Job)
    if ($Job.PSObject.Properties.Name -notcontains 'sharedTerminal' -or -not [bool]$Job.sharedTerminal) {
        return
    }
    if ($Job.PSObject.Properties.Name -contains 'terminalControlState') {
        $Job.terminalControlState = 'released'
    } else {
        $Job | Add-Member -NotePropertyName terminalControlState -NotePropertyValue 'released'
    }
}

function Get-PreHostStaleAllowanceSeconds {
    param($Job)
    # A cold-start shared-terminal launch legitimately holds its starting record
    # without a host through every bounded bootstrap stage: the bootstrap-lock
    # wait (60s), the post-lock re-probe (3 x 5s probes plus retry delays, ~16s),
    # the activation loop (30s nominal, overrunning by one final blocking
    # re-probe, ~46s), and the new-tab CLI call (10s). The reservation must
    # outlive that ~132s worst case, plus scheduling margin, before
    # reconciliation may orphan it.
    if ($Job.PSObject.Properties.Name -contains 'terminalLaunchMode' -and
        [string]$Job.terminalLaunchMode -eq 'foreground-bootstrap') {
        return 180
    }
    return 30
}

function Update-ReconciledJob {
    param($Job)
    if ($Job.status -notin @('starting', 'running')) {
        Remove-ManagedJobControl -JobId $Job.id
        try { Unregister-ManagedJobOwnerReference -Job $Job } catch {}
        return $Job
    }
    if ($Job.status -eq 'starting' -and -not $Job.hostPid) {
        $createdAt = if ($Job.createdAtUtc -is [datetime]) {
            $Job.createdAtUtc.ToUniversalTime()
        } else {
            [datetimeoffset]::Parse([string]$Job.createdAtUtc).UtcDateTime
        }
        if (([datetime]::UtcNow - $createdAt).TotalSeconds -lt (Get-PreHostStaleAllowanceSeconds -Job $Job)) { return $Job }
    }
    if (Test-ManagedProcessIdentity -ProcessId $Job.hostPid -ExpectedStartTimeUtc $Job.hostStartedAtUtc) { return $Job }
    $path = Get-ManagedJobFile -Id $Job.id
    $current = Read-ManagedJob -Path $path
    if ($current.status -notin @('starting', 'running')) {
        Remove-ManagedJobControl -JobId $current.id
        try { Unregister-ManagedJobOwnerReference -Job $current } catch {}
        return $current
    }
    if ($current.status -eq 'starting' -and -not $current.hostPid) {
        $createdAt = if ($current.createdAtUtc -is [datetime]) {
            $current.createdAtUtc.ToUniversalTime()
        } else {
            [datetimeoffset]::Parse([string]$current.createdAtUtc).UtcDateTime
        }
        if (([datetime]::UtcNow - $createdAt).TotalSeconds -lt (Get-PreHostStaleAllowanceSeconds -Job $current)) { return $current }
    }
    if (Test-ManagedProcessIdentity -ProcessId $current.hostPid -ExpectedStartTimeUtc $current.hostStartedAtUtc) { return $current }
    $current.status = 'orphaned'
    Set-ManagedJobControlReleased -Job $current
    $current.finishedAtUtc = [datetime]::UtcNow.ToString('o')
    $current.error = 'Recorded host process is no longer running and no terminal state was recorded.'
    Write-ManagedJob -Path $path -Job $current
    Remove-ManagedJobControl -JobId $current.id
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

function Get-ManagedJobsWithActiveReconciliation {
    foreach ($job in Get-AllManagedJobs) {
        if ($job.status -in @('starting', 'running')) {
            Update-ReconciledJob -Job $job
        } else {
            $job
        }
    }
}

function Enter-ManagedJobMaintenanceLock {
    param(
        [switch]$Wait,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
    )

    $lockPath = Join-Path (Get-ManagedJobRoot) '.maintenance.lock'
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            return [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        } catch [IO.IOException] {
            if (-not $Wait) {
                throw 'Another managed-jobs maintenance operation is already running.'
            }
            if ([datetime]::UtcNow -ge $deadline) {
                throw "Timed out after $TimeoutSeconds seconds waiting for another managed-jobs maintenance operation."
            }
            Start-Sleep -Milliseconds 250
        }
    } while ($true)
}

function Get-PruneCandidates {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Jobs,
        [Parameter(Mandatory)][datetime]$Cutoff,
        [string[]]$StatusFilter
    )

    foreach ($job in @($Jobs)) {
        if ($job.status -in @('starting', 'running', 'invalid')) { continue }
        if ($StatusFilter -and $job.status -notin $StatusFilter) { continue }
        $timestampText = if ($job.finishedAtUtc) { $job.finishedAtUtc } else { $job.createdAtUtc }
        $timestamp = if ($timestampText -is [datetime]) {
            $timestampText.ToUniversalTime()
        } else {
            [datetimeoffset]::Parse([string]$timestampText).UtcDateTime
        }
        if ($timestamp -lt $Cutoff) { $job }
    }
}

function Read-PruneMaintenancePlan {
    param([Parameter(Mandatory)][string]$Path)

    $maintenanceDirectory = [IO.Path]::GetFullPath(
        (Join-Path (Get-ManagedJobRoot) 'maintenance')
    )
    $maintenancePrefix = [IO.Path]::TrimEndingDirectorySeparator($maintenanceDirectory) +
        [IO.Path]::DirectorySeparatorChar
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith($maintenancePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The prune maintenance plan must be inside the managed-jobs maintenance directory.'
    }
    $plan = Read-ManagedJob -Path $resolvedPath
    if ($plan.PSObject.Properties.Name -notcontains 'schemaVersion' -or
        [int]$plan.schemaVersion -ne 1 -or
        $plan.PSObject.Properties.Name -notcontains 'action' -or
        [string]$plan.action -ne 'prune' -or
        $plan.PSObject.Properties.Name -notcontains 'cutoffUtc' -or
        $plan.PSObject.Properties.Name -notcontains 'statuses' -or
        $plan.PSObject.Properties.Name -notcontains 'candidateIds') {
        throw 'The prune maintenance plan is invalid.'
    }
    $allowedStatuses = @('starting', 'running', 'completed', 'failed', 'stopped', 'orphaned', 'invalid')
    $statusFilter = @($plan.statuses | ForEach-Object {
        $value = [string]$_
        if (-not [string]::IsNullOrWhiteSpace($value)) { $value }
    })
    if (@($statusFilter | Where-Object { $_ -notin $allowedStatuses }).Count -gt 0) {
        throw 'The prune maintenance plan contains an invalid status filter.'
    }
    $candidateIds = @($plan.candidateIds | ForEach-Object { [string]$_ } | Select-Object -Unique)
    foreach ($candidateId in $candidateIds) {
        $null = Get-ManagedJobFile -Id $candidateId
    }
    $cutoff = if ($plan.cutoffUtc -is [datetime]) {
        $plan.cutoffUtc.ToUniversalTime()
    } else {
        [datetimeoffset]::Parse([string]$plan.cutoffUtc).UtcDateTime
    }
    Remove-Item -LiteralPath $resolvedPath -Force
    return [pscustomobject]@{
        path = $resolvedPath
        cutoff = $cutoff
        statuses = $statusFilter
        candidateIds = $candidateIds
    }
}

function Start-ManagedJobMaintenance {
    param([Parameter(Mandatory)][ValidateSet('reconcile', 'prune')][string]$MaintenanceAction)

    $probe = Enter-ManagedJobMaintenanceLock
    $probe.Dispose()
    $root = Get-ManagedJobRoot
    $maintenanceScript = Join-Path $PSScriptRoot 'ManagedJob.Maintenance.ps1'
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $maintenanceArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $maintenanceScript,
        '-Controller', $PSCommandPath,
        '-Action', $MaintenanceAction,
        '-StateRoot', $root
    )
    $maintenanceEvidence = [ordered]@{ action = $MaintenanceAction }
    $planPath = $null
    if ($Status) {
        $maintenanceArguments += @('-StatusCsv', ($Status -join ','))
        $maintenanceEvidence.statuses = @($Status)
    }
    if ($MaintenanceAction -eq 'prune') {
        $cutoff = [datetime]::UtcNow.AddDays(-[math]::Abs($OlderThanDays))
        $candidateIds = @(
            Get-PruneCandidates -Jobs @(Get-AllManagedJobs) -Cutoff $cutoff -StatusFilter $Status |
                Select-Object -ExpandProperty id
        )
        $maintenanceDirectory = Join-Path $root 'maintenance'
        $null = New-Item -ItemType Directory -Path $maintenanceDirectory -Force
        $planPath = Join-Path $maintenanceDirectory ('prune-' + [guid]::NewGuid().ToString('N') + '.json')
        Write-ManagedJson -Path $planPath -Value ([ordered]@{
            schemaVersion = 1
            action = 'prune'
            createdAtUtc = [datetime]::UtcNow.ToString('o')
            cutoffUtc = $cutoff.ToString('o')
            statuses = @($Status)
            candidateIds = $candidateIds
        })
        $maintenanceArguments += @('-PlanPath', $planPath)
        $maintenanceEvidence.cutoffUtc = $cutoff.ToString('o')
        $maintenanceEvidence.plannedCandidateCount = $candidateIds.Count
    }

    try {
        $job = (& $PSCommandPath start `
            -StateRoot $root `
            -Name "managed-jobs-$MaintenanceAction" `
            -Kind maintenance `
            -Executable $pwsh `
            -Arguments $maintenanceArguments `
            -WorkingDirectory $root `
            -Lifetime Persistent | Out-String) | ConvertFrom-Json
    } catch {
        if ($planPath -and (Test-Path -LiteralPath $planPath -PathType Leaf)) {
            Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    $output = [ordered]@{}
    foreach ($property in $job.PSObject.Properties) { $output[$property.Name] = $property.Value }
    $output.maintenance = [pscustomobject]$maintenanceEvidence
    [pscustomobject]$output | ConvertTo-Json -Depth 12
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

function Resolve-ManagedJobReadinessUri {
    param([Parameter(Mandatory)][uri]$Uri)

    if (-not $Uri.IsAbsoluteUri) {
        throw '-ReadinessUri must be an absolute HTTP or HTTPS URL.'
    }
    if ($Uri.Scheme -notin @('http', 'https')) {
        throw '-ReadinessUri must be an absolute HTTP or HTTPS URL.'
    }
    if ($Uri.UserInfo -or $Uri.Query -or $Uri.Fragment) {
        throw '-ReadinessUri must not contain credentials, a query, or a fragment.'
    }
    $address = $null
    $readinessHost = $Uri.DnsSafeHost
    $isLoopback = $readinessHost.Equals('localhost', [StringComparison]::OrdinalIgnoreCase) -or
        ([Net.IPAddress]::TryParse($readinessHost, [ref]$address) -and [Net.IPAddress]::IsLoopback($address))
    if (-not $isLoopback) {
        throw '-ReadinessUri must target localhost or a loopback IP address.'
    }
    return $Uri.AbsoluteUri
}

function Wait-ManagedJobReadiness {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $started = [Diagnostics.Stopwatch]::StartNew()
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $attempts = 0
    $lastResult = 'no response'
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    try {
        do {
            $job = Update-ReconciledJob -Job (Read-ManagedJob -Path (Get-ManagedJobFile -Id $JobId))
            if ($job.status -notin @('starting', 'running')) {
                throw "Managed job $JobId reached status '$($job.status)' before $Uri became ready."
            }

            $attempts++
            $response = $null
            $readyStatusCode = $null
            $probeCancellation = $null
            try {
                $remainingMilliseconds = [Math]::Max(1, ($deadline - [datetime]::UtcNow).TotalMilliseconds)
                $probeCancellation = [Threading.CancellationTokenSource]::new(
                    [TimeSpan]::FromMilliseconds([Math]::Min(2000, $remainingMilliseconds))
                )
                $response = $client.GetAsync(
                    $Uri,
                    [Net.Http.HttpCompletionOption]::ResponseHeadersRead,
                    $probeCancellation.Token
                ).GetAwaiter().GetResult()
                $statusCode = [int]$response.StatusCode
                $lastResult = "HTTP $statusCode"
                if ($statusCode -ge 200 -and $statusCode -lt 400) {
                    $readyStatusCode = $statusCode
                }
            } catch {
                $probeFailure = $_.Exception.GetBaseException()
                $lastResult = if ($probeCancellation -and $probeCancellation.IsCancellationRequested) {
                    'probe exceeded its response budget'
                } else {
                    $probeFailure.Message
                }
            } finally {
                if ($response) { $response.Dispose() }
                if ($probeCancellation) { $probeCancellation.Dispose() }
            }

            if ($null -ne $readyStatusCode) {
                Start-Sleep -Milliseconds 100
                $confirmedJob = Update-ReconciledJob -Job (
                    Read-ManagedJob -Path (Get-ManagedJobFile -Id $JobId)
                )
                if ($confirmedJob.status -notin @('starting', 'running')) {
                    throw "Managed job $JobId reached status '$($confirmedJob.status)' immediately after the readiness response."
                }
                return [pscustomobject][ordered]@{
                    status = 'ready'
                    uri = $Uri
                    httpStatusCode = $readyStatusCode
                    attempts = $attempts
                    checkedAtUtc = [datetime]::UtcNow.ToString('o')
                    elapsedMilliseconds = [long][Math]::Round($started.Elapsed.TotalMilliseconds)
                }
            }

            if ([datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
        } while ([datetime]::UtcNow -lt $deadline)
    } finally {
        $client.Dispose()
        $handler.Dispose()
        $started.Stop()
    }
    throw "Managed job $JobId was not ready at $Uri after $TimeoutSeconds seconds ($attempts attempts; last result: $lastResult)."
}

function Add-ManagedJobReadiness {
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)]$Readiness
    )

    $copy = [ordered]@{}
    foreach ($property in $Job.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    $copy.readiness = $Readiness
    return [pscustomobject]$copy
}

function Get-SharedTerminalContext {
    param([Parameter(Mandatory)][string]$JobId)

    $job = Update-ReconciledJob -Job (Read-ManagedJob -Path (Get-ManagedJobFile -Id $JobId))
    if ($job.PSObject.Properties.Name -notcontains 'sharedTerminal' -or -not [bool]$job.sharedTerminal) {
        throw "Job $JobId was not started in shared-terminal mode."
    }
    if ($job.status -ne 'running') {
        throw "Job $JobId is not available for shared-terminal control; current status is $($job.status)."
    }
    if (-not (Test-ManagedProcessIdentity -ProcessId $job.hostPid -ExpectedStartTimeUtc $job.hostStartedAtUtc)) {
        throw "Job $JobId does not have a matching managed-host identity."
    }
    if ($job.PSObject.Properties.Name -notcontains 'processContainment' -or
        [string]$job.processContainment -ne 'windows-job-object-kill-on-close') {
        throw "Job $JobId has not confirmed Windows process-tree containment."
    }

    if ($job.PSObject.Properties.Name -notcontains 'terminalControlState' -or
        [string]$job.terminalControlState -ne 'registered') {
        throw "Job $JobId has invalid shared-terminal control metadata."
    }
    $controlFile = Get-ManagedJobControlFile -Id $JobId
    if (-not (Test-Path -LiteralPath $controlFile -PathType Leaf)) {
        throw "Job $JobId has invalid shared-terminal control metadata."
    }
    try {
        $control = Read-ManagedJob -Path $controlFile
    } catch {
        throw "Job $JobId has invalid shared-terminal control metadata."
    }
    $requiredControlProperties = @(
        'schemaVersion', 'jobId', 'hostPid', 'hostStartedAtUtc', 'wtSession', 'wtComClsid'
    )
    if (@($requiredControlProperties | Where-Object { $control.PSObject.Properties.Name -notcontains $_ }).Count -gt 0 -or
        [int]$control.schemaVersion -ne 1) {
        throw "Job $JobId has invalid shared-terminal control metadata."
    }
    $terminalSession = [guid]::Empty
    $terminalComClsid = [guid]::Empty
    $controlStart = $null
    try { $controlStart = [datetimeoffset]::Parse([string]$control.hostStartedAtUtc).UtcDateTime } catch {}
    $jobStart = [datetimeoffset]::Parse([string]$job.hostStartedAtUtc).UtcDateTime
    if ([string]$control.jobId -ne $JobId -or
        [int]$control.hostPid -ne [int]$job.hostPid -or
        -not $controlStart -or
        [math]::Abs(($controlStart - $jobStart).TotalSeconds) -ge 2 -or
        -not [guid]::TryParse([string]$control.wtSession, [ref]$terminalSession) -or
        -not [guid]::TryParse([string]$control.wtComClsid, [ref]$terminalComClsid)) {
        throw "Job $JobId has invalid shared-terminal control metadata."
    }

    return [pscustomobject]@{
        job = $job
        sessionId = $terminalSession.ToString('D')
        comClsid = $terminalComClsid.ToString('B')
        tools = Resolve-RecordedIntelligentTerminalTools -Job $job
    }
}

function Invoke-SharedTerminalCli {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $result = Invoke-IntelligentTerminalCliProcess `
        -Tools $Context.tools `
        -ComClsid $Context.comClsid `
        -SessionId $Context.sessionId `
        -Arguments $Arguments
    if ($result.exitCode -ne 0) {
        $detail = $result.standardError.Trim()
        try {
            foreach ($privateValue in @(
                [string]$Context.sessionId,
                ([guid]$Context.sessionId).ToString('B'),
                [string]$Context.comClsid,
                ([guid]$Context.comClsid).ToString('D')
            )) {
                if ($privateValue) {
                    $detail = $detail -replace [regex]::Escape($privateValue), '<redacted>'
                }
            }
        } catch {}
        if ($detail.Length -gt 1000) { $detail = $detail.Substring(0, 1000) }
        if ($detail) { throw "The shared-terminal controller failed: $detail" }
        throw "The shared-terminal controller failed with exit code $($result.exitCode)."
    }
    return $result.standardOutput
}

function Start-ManagedJobBackgroundTerminalTab {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$PowerShellArguments
    )

    $commandLine = (@('pwsh.exe') + $PowerShellArguments) -join ' '
    $terminalArguments = @(
        '--json', 'new-tab',
        '--command', $commandLine,
        '--title', $Name,
        '--cwd', $WorkingDirectory
    )
    $powerShellProfile = Resolve-PowerShellTerminalProfile -Connection $Connection
    if ($powerShellProfile) {
        $profileSelector = if ($powerShellProfile.id) { $powerShellProfile.id } else { $powerShellProfile.name }
        $terminalArguments += @('--profile', $profileSelector)
    }
    $result = Invoke-IntelligentTerminalCliProcess `
        -Tools $Connection.tools `
        -ComClsid $Connection.comClsid `
        -Arguments $terminalArguments
    if ($result.exitCode -ne 0) {
        $detail = $result.standardError.Trim()
        try {
            $comClsid = [guid]$Connection.comClsid
            foreach ($privateValue in @($comClsid.ToString('B'), $comClsid.ToString('D'))) {
                $detail = $detail -replace [regex]::Escape($privateValue), '<redacted>'
            }
        } catch {}
        if ($detail.Length -gt 1000) { $detail = $detail.Substring(0, 1000) }
        if ($detail) { throw "The background shared-terminal tab failed to launch: $detail" }
        throw 'The background shared-terminal tab failed to launch.'
    }
    try {
        $payload = $result.standardOutput | ConvertFrom-Json
        $sessionId = [guid]::Empty
        if (-not [guid]::TryParse([string]$payload.session_id, [ref]$sessionId)) {
            throw 'missing session identifier'
        }
        return $sessionId.ToString('D')
    } catch {
        throw [InvalidOperationException]::new(
            'The background shared-terminal tab returned an invalid result.',
            $_.Exception
        )
    }
}

function Stop-ManagedJobBackgroundTerminalTab {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$SessionId
    )

    $result = Invoke-IntelligentTerminalCliProcess `
        -Tools $Connection.tools `
        -ComClsid $Connection.comClsid `
        -Arguments @('kill-pane', '--target', $SessionId)
    if ($result.exitCode -ne 0) {
        throw 'The background shared-terminal tab could not be closed.'
    }
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

function Stop-ManagedJobTrees {
    param([Parameter(Mandatory)][object[]]$Request)

    $outcomes = [Collections.Generic.List[object]]::new()
    $targets = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Request)) {
        $job = $item.job
        $outcome = [pscustomobject][ordered]@{
            matched = $false
            job = $job
            error = $null
        }
        $outcomes.Add($outcome) | Out-Null
        try {
            $path = Get-ManagedJobFile -Id $job.id
            try {
                $current = Read-ManagedJob -Path $path
                $recordUnavailable = $false
            } catch {
                if (-not ($item.PSObject.Properties.Name -contains 'allowRecordFallback') -or
                    -not $item.allowRecordFallback) {
                    throw
                }
                $current = $job
                $recordUnavailable = $true
            }
            $outcome.job = $current
            if ($current.status -notin @('starting', 'running')) {
                Remove-ManagedJobControl -JobId $current.id
                try { Unregister-ManagedJobOwnerReference -Job $current } catch {}
                continue
            }
            if (-not (Test-ManagedProcessIdentity -ProcessId $current.hostPid -ExpectedStartTimeUtc $current.hostStartedAtUtc)) {
                if ($recordUnavailable) {
                    $current.status = 'stopped'
                    Set-ManagedJobControlReleased -Job $current
                    $current.finishedAtUtc = [datetime]::UtcNow.ToString('o')
                    $current.exitCode = $null
                    $current.error = [string]$item.reason
                    Remove-ManagedJobControl -JobId $current.id
                    Unregister-ManagedJobOwnerReference -Job $current
                    $outcome.job = $current
                    continue
                }
                $current = Update-ReconciledJob -Job $current
                $outcome.job = $current
                if ($current.status -notin @('starting', 'running')) { continue }
                throw "Job $($current.id) has not published a verifiable host process yet."
            }
            if ($current.PSObject.Properties.Name -notcontains 'processContainment' -or
                [string]$current.processContainment -ne 'windows-job-object-kill-on-close') {
                throw "Job $($current.id) has not confirmed Windows process-tree containment."
            }
            $outcome.matched = $true

            $stopErrors = @()
            Stop-Process `
                -Id ([int]$current.hostPid) `
                -Force `
                -ErrorAction SilentlyContinue `
                -ErrorVariable +stopErrors
            $targets.Add([pscustomobject][ordered]@{
                outcome = $outcome
                path = $path
                reason = [string]$item.reason
                hostPid = $current.hostPid
                hostStartedAtUtc = $current.hostStartedAtUtc
                stopErrors = @($stopErrors)
                recordUnavailable = $recordUnavailable
            }) | Out-Null
        } catch {
            $outcome.error = $_.Exception.Message
            try { $outcome.job = Read-ManagedJob -Path (Get-ManagedJobFile -Id $job.id) } catch {}
        }
    }

    if ($targets.Count -gt 0) {
        $stopDeadline = [datetime]::UtcNow.AddSeconds(1)
        do {
            $stillRunning = @($targets | Where-Object {
                Test-ManagedProcessIdentity `
                    -ProcessId $_.hostPid `
                    -ExpectedStartTimeUtc $_.hostStartedAtUtc
            })
            if ($stillRunning.Count -eq 0 -or [datetime]::UtcNow -ge $stopDeadline) { break }
            Start-Sleep -Milliseconds 25
        } while ($true)

        foreach ($target in $targets) {
            try {
                if (Test-ManagedProcessIdentity `
                    -ProcessId $target.hostPid `
                    -ExpectedStartTimeUtc $target.hostStartedAtUtc) {
                    $detail = if ($target.stopErrors.Count -gt 0) {
                        ': ' + (@($target.stopErrors | ForEach-Object { $_.Exception.Message }) -join ' | ')
                    } else {
                        ''
                    }
                    throw "Unable to terminate PID $($target.hostPid)$detail"
                }
                $current = $target.outcome.job
                if ($target.recordUnavailable) {
                    $current.status = 'stopped'
                    Set-ManagedJobControlReleased -Job $current
                    $current.finishedAtUtc = [datetime]::UtcNow.ToString('o')
                    $current.exitCode = $null
                    $current.error = $target.reason
                } else {
                    $current = Read-ManagedJob -Path $target.path
                    if ($current.status -in @('starting', 'running')) {
                        $current.status = 'stopped'
                        Set-ManagedJobControlReleased -Job $current
                        $current.finishedAtUtc = [datetime]::UtcNow.ToString('o')
                        $current.exitCode = $null
                        $current.error = $target.reason
                        Write-ManagedJob -Path $target.path -Job $current
                    }
                }
                Remove-ManagedJobControl -JobId $current.id
                Unregister-ManagedJobOwnerReference -Job $current
                $target.outcome.job = $current
            } catch {
                $target.outcome.error = $_.Exception.Message
                try { $target.outcome.job = Read-ManagedJob -Path $target.path } catch {}
            }
        }
    }
    return @($outcomes)
}

if ($Async) {
    Start-ManagedJobMaintenance -MaintenanceAction $Action
    return
}

switch ($Action) {
    'start' {
        if (-not $Name) { throw '-Name is required for start.' }
        if (-not $Executable) { throw '-Executable is required for start.' }
        if ($KeepTerminalOpen -and -not $Visible) { throw '-KeepTerminalOpen requires -Visible.' }
        if ($SharedTerminal -and -not $Visible) { throw '-SharedTerminal requires -Visible.' }
        if ($RequireBackgroundTab -and -not $SharedTerminal) {
            throw '-RequireBackgroundTab requires -SharedTerminal.'
        }
        if ($PSBoundParameters.ContainsKey('ReadinessTimeoutSeconds') -and -not $ReadinessUri) {
            throw '-ReadinessTimeoutSeconds requires -ReadinessUri.'
        }
        $resolvedReadinessUri = if ($ReadinessUri) { Resolve-ManagedJobReadinessUri -Uri $ReadinessUri } else { $null }
        $terminalTools = if ($SharedTerminal) { Resolve-IntelligentTerminalTools } else { $null }
        $backgroundTerminalConnection = if ($SharedTerminal) {
            Get-LiveIntelligentTerminalConnection -Tools $terminalTools
        } else {
            $null
        }
        if ($RequireBackgroundTab -and -not $backgroundTerminalConnection) {
            throw '-RequireBackgroundTab needs an already-running Microsoft Intelligent Terminal window.'
        }
        $sharedTerminalLaunchMode = if (-not $SharedTerminal) {
            $null
        } elseif ($backgroundTerminalConnection) {
            'background-tab'
        } else {
            'foreground-bootstrap'
        }
        Assert-SecretSafeInvocation -Arguments $Arguments -Environment $Environment
        $resolvedOwnerAgent = if ($OwnerAgent) {
            $OwnerAgent.Trim().ToLowerInvariant()
        } elseif ($isCodexInstallation -and $env:CODEX_THREAD_ID) {
            'codex'
        } elseif ($isClaudeInstallation -and $env:CLAUDE_CODE_SESSION_ID) {
            'claude'
        } else {
            $null
        }
        $resolvedOwnerSessionId = if ($OwnerSessionId) {
            $OwnerSessionId.Trim()
        } elseif ($isCodexInstallation -and $env:CODEX_THREAD_ID) {
            $env:CODEX_THREAD_ID.Trim()
        } elseif ($isClaudeInstallation -and $env:CLAUDE_CODE_SESSION_ID) {
            $env:CLAUDE_CODE_SESSION_ID.Trim()
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
            throw "Lifetime '$Lifetime' requires -OwnerAgent and -OwnerSessionId, or an agent invocation that provides CODEX_THREAD_ID or CLAUDE_CODE_SESSION_ID."
        }
        $resolvedRoot = [IO.Path]::GetFullPath((Get-ManagedJobRoot))
        if ($resolvedLifetime -in @('turn', 'session') -and
            -not $resolvedRoot.Equals($automaticCleanupRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Lifetime '$Lifetime' requires the hook-visible managed-job state root '$automaticCleanupRoot'. Set MANAGED_JOBS_ROOT before starting the agent instead of using a different -StateRoot, or use -Lifetime Persistent."
        }
        $resolvedDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
        $fingerprint = Get-InvocationFingerprint -Executable $Executable -Arguments $Arguments -WorkingDirectory $resolvedDirectory -Environment $Environment
        $root = Get-ManagedJobRoot
        $lockPath = Join-Path $root '.launch.lock'
        $lock = $null
        $launchFile = $null
        $jobFile = $null
        $jobId = $null
        $expectedTerminalSession = $null
        $backgroundTabMayExist = $false
        try {
            $deadline = [datetime]::UtcNow.AddSeconds(10)
            do {
                try { $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') } catch [IO.IOException] {
                    if ([datetime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the managed-jobs launch lock.' }
                    Start-Sleep -Milliseconds 100
                }
            } until ($lock)

            $active = @(Get-ManagedJobsWithActiveReconciliation | Where-Object status -in @('starting', 'running'))
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
            foreach ($environmentKey in $Environment.Keys) {
                $environmentObject[[string]$environmentKey] = [string]$Environment[$environmentKey]
            }
            $job = [ordered]@{
                schemaVersion = if ($SharedTerminal) { 4 } else { 3 }
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
            if ($SharedTerminal) {
                $job['sharedTerminal'] = $true
                $job['terminalPackageVersion'] = $terminalTools.packageVersion
                $job['terminalPackageRoot'] = $terminalTools.packageRoot
                $job['terminalCliPath'] = $terminalTools.wtcli
                $job['terminalControlState'] = 'pending'
                $job['terminalLaunchMode'] = $sharedTerminalLaunchMode
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

            # The durable record now reserves this invocation fingerprint against
            # concurrent duplicates, so the launch lock is released instead of
            # being held through the slow cold-start bootstrap below.
            $lock.Dispose()
            $lock = $null
            if ($SharedTerminal -and -not $backgroundTerminalConnection) {
                # Cold start opens a user-visible window, so it runs only after
                # validation succeeded and this request's record was reserved. A
                # dedicated lock serializes concurrent cold starts, and its
                # holder re-probes first so they reuse one activated window
                # instead of opening several.
                $bootstrapLockPath = Join-Path $root '.bootstrap.lock'
                $bootstrapLock = $null
                $bootstrapDeadline = [datetime]::UtcNow.AddSeconds(60)
                do {
                    try { $bootstrapLock = [IO.File]::Open($bootstrapLockPath, 'OpenOrCreate', 'ReadWrite', 'None') } catch [IO.IOException] {
                        if ([datetime]::UtcNow -ge $bootstrapDeadline) { throw 'Timed out waiting for the shared-terminal bootstrap lock.' }
                        Start-Sleep -Milliseconds 200
                    }
                } until ($bootstrapLock)
                try {
                    $backgroundTerminalConnection = Get-LiveIntelligentTerminalConnection -Tools $terminalTools
                    if (-not $backgroundTerminalConnection) {
                        $backgroundTerminalConnection = Start-IntelligentTerminalWindow -Tools $terminalTools
                    }
                } finally {
                    $bootstrapLock.Dispose()
                }
            }

            if ($Visible) {
                $pwshArguments = if ($SharedTerminal) {
                    Get-ManagedJobHostPowerShellArguments `
                        -HostScript $hostScript `
                        -JobFile $jobFile `
                        -LaunchFile $launchFile `
                        -KeepOpen:$KeepTerminalOpen
                } else {
                    $ordinaryVisibleArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
                    if ($KeepTerminalOpen) { $ordinaryVisibleArguments += '-NoExit' }
                    $ordinaryVisibleArguments + @(
                        '-File', ('"' + $hostScript + '"'),
                        '-JobFile', ('"' + $jobFile + '"'),
                        '-LaunchFile', ('"' + $launchFile + '"')
                    )
                }
                if ($SharedTerminal) {
                    # Once control reaches wtcli, any failure can be ambiguous: the
                    # tab may have been created before the client timed out or exited.
                    $backgroundTabMayExist = $true
                    $expectedTerminalSession = Start-ManagedJobBackgroundTerminalTab `
                        -Connection $backgroundTerminalConnection `
                        -Name $Name `
                        -WorkingDirectory $resolvedDirectory `
                        -PowerShellArguments $pwshArguments
                } else {
                    $terminalExecutable = (Get-Command wt.exe -ErrorAction Stop).Source
                    $terminalArguments = @('-w', 'managed-jobs', 'new-tab', '--title', $Name, 'pwsh.exe') + $pwshArguments
                    Start-Process -FilePath $terminalExecutable -ArgumentList $terminalArguments -WindowStyle Hidden | Out-Null
                }
            } else {
                # Start-Process -WindowStyle Hidden is ignored when Windows Terminal is
                # the default terminal app, so hidden hosts launch with CreateNoWindow.
                $startInfo = [Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName = 'pwsh.exe'
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                foreach ($hostArgument in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hostScript, '-JobFile', $jobFile, '-LaunchFile', $launchFile)) {
                    $startInfo.ArgumentList.Add($hostArgument)
                }
                $hostProcess = [Diagnostics.Process]::Start($startInfo)
                if (-not $hostProcess) { throw 'Hidden managed-job host process failed to start.' }
                $hostProcess.Dispose()
            }
        } catch {
            # Recovery can wait for an ambiguously-created terminal host. Do not
            # block unrelated launches while that job-scoped recovery runs.
            if ($lock) {
                $lock.Dispose()
                $lock = $null
            }
            $launchFailure = $_.Exception.Message
            $backgroundTerminationError = $null
            $preserveBackgroundOwnership = $false
            if ($backgroundTabMayExist -and $jobFile -and (Test-Path -LiteralPath $jobFile)) {
                $recoveryDeadline = [datetime]::UtcNow.AddSeconds(30)
                do {
                    try { $backgroundJob = Read-ManagedJob -Path $jobFile } catch { $backgroundJob = $null }
                    if (-not $backgroundJob -or $backgroundJob.status -ne 'starting') { break }
                    Start-Sleep -Milliseconds 100
                } while ([datetime]::UtcNow -lt $recoveryDeadline)
                if ($backgroundJob -and $backgroundJob.status -eq 'running') {
                    $terminationRequest = [pscustomobject]@{
                        job = $backgroundJob
                        reason = 'Stopped because background tab launch did not return a valid result.'
                    }
                    $termination = @(Stop-ManagedJobTrees -Request @($terminationRequest))[0]
                    if ($termination.error) {
                        $backgroundTerminationError = [string]$termination.error
                        $preserveBackgroundOwnership = $true
                    }
                } elseif ($backgroundJob -and $backgroundJob.status -eq 'starting') {
                    # The tab may still claim the launch after this invocation fails.
                    # Cancel new claims but retain the owner reference so cleanup can
                    # contain a host that already read the handoff.
                    $backgroundJob.error = 'Background tab launch returned an invalid result before the host published its identity.'
                    Write-ManagedJob -Path $jobFile -Job $backgroundJob
                    $preserveBackgroundOwnership = $true
                }
            }
            if ($launchFile -and (Test-Path -LiteralPath $launchFile)) { Remove-Item -LiteralPath $launchFile -Force -ErrorAction SilentlyContinue }
            if ($jobId -and -not $preserveBackgroundOwnership) { Remove-ManagedJobControl -JobId $jobId }
            if ($jobFile -and (Test-Path -LiteralPath $jobFile)) {
                try {
                    $failedJob = Read-ManagedJob -Path $jobFile
                    if ($failedJob.status -eq 'starting' -and -not $preserveBackgroundOwnership) {
                        $failedJob.status = 'failed'
                        Set-ManagedJobControlReleased -Job $failedJob
                        $failedJob.finishedAtUtc = [datetime]::UtcNow.ToString('o')
                        $failedJob.error = 'Managed host launch failed before startup completed.'
                        Write-ManagedJob -Path $jobFile -Job $failedJob
                        Unregister-ManagedJobOwnerReference -Job $failedJob
                    }
                } catch {}
            }
            if ($backgroundTerminationError) {
                throw "$launchFailure Failed to contain the background terminal host: $backgroundTerminationError"
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
        # A slow host may claim immediately after the final poll. Re-read before
        # deciding whether the background launch needs cancellation.
        if ($job.status -eq 'starting') { $job = Read-ManagedJob -Path $jobFile }
        if ($expectedTerminalSession -and $job.status -eq 'starting') {
            # Cancel the unclaimed handoff first. If the host already removed it,
            # give that concurrent claim time to publish its identity before acting.
            if (Test-Path -LiteralPath $launchFile) {
                Remove-Item -LiteralPath $launchFile -Force -ErrorAction SilentlyContinue
            }
            $claimDeadline = [datetime]::UtcNow.AddSeconds(5)
            do {
                Start-Sleep -Milliseconds 100
                $current = Read-ManagedJob -Path $jobFile
            } while ($current.status -eq 'starting' -and [datetime]::UtcNow -lt $claimDeadline)
            $job = $current
            if ($job.status -eq 'starting') {
                $backgroundCloseError = $null
                try {
                    Stop-ManagedJobBackgroundTerminalTab `
                        -Connection $backgroundTerminalConnection `
                        -SessionId $expectedTerminalSession
                } catch {
                    $backgroundCloseError = $_.Exception.Message
                }
                $afterClose = Read-ManagedJob -Path $jobFile
                if ($afterClose.status -ne 'starting') {
                    # The host can publish and finish while cancellation is in
                    # flight. Preserve any running or terminal result it recorded.
                    $job = $afterClose
                    $backgroundCloseError = $null
                } elseif ($backgroundCloseError) {
                    # The pane may still publish a host identity. Keep the active
                    # owner reference so turn/session cleanup can contain it.
                    $afterClose.error = 'Background terminal host missed its startup deadline and its pane could not be confirmed closed.'
                    Write-ManagedJob -Path $jobFile -Job $afterClose
                    throw "The background shared-terminal host did not start in time, and its tab could not be closed safely: $backgroundCloseError"
                }
                if ($job.status -eq 'starting') {
                    Remove-ManagedJobControl -JobId $job.id
                    $job.status = 'failed'
                    Set-ManagedJobControlReleased -Job $job
                    $job.finishedAtUtc = [datetime]::UtcNow.ToString('o')
                    $job.error = 'Background terminal host did not publish its process identity before the startup deadline.'
                    Write-ManagedJob -Path $jobFile -Job $job
                    Unregister-ManagedJobOwnerReference -Job $job
                    if ($backgroundCloseError) {
                        throw "The background shared-terminal host did not start in time, and its tab could not be closed safely: $backgroundCloseError"
                    }
                    throw 'The background shared-terminal host did not start in time.'
                }
            }
        }
        if ($expectedTerminalSession -and $job.status -eq 'running') {
            $registeredSession = [guid]::Empty
            $sessionMatches = $false
            try {
                $control = Read-ManagedJob -Path (Get-ManagedJobControlFile -Id $job.id)
                $sessionMatches = [guid]::TryParse([string]$control.wtSession, [ref]$registeredSession) -and
                    $registeredSession.ToString('D') -eq $expectedTerminalSession
            } catch {}
            if (-not $sessionMatches) {
                $latest = Update-ReconciledJob -Job (Read-ManagedJob -Path $jobFile)
                if ($latest.status -ne 'running') {
                    # Normal completion can remove the control file between the
                    # status read and identity check. Preserve that terminal result.
                    $job = $latest
                } else {
                    $terminationRequest = [pscustomobject]@{
                        job = $latest
                        reason = 'Stopped because its background terminal session identity did not match.'
                    }
                    $termination = @(Stop-ManagedJobTrees -Request @($terminationRequest))[0]
                    if ($termination.error) {
                        throw "The background shared-terminal host registered an unexpected pane and could not be stopped safely: $($termination.error)"
                    }
                    throw 'The background shared-terminal host registered an unexpected pane.'
                }
            }
        }
        $jobOutput = Add-ManagedJobIdentity -Job $job
        if ($resolvedReadinessUri) {
            try {
                $readiness = Wait-ManagedJobReadiness `
                    -JobId $job.id `
                    -Uri $resolvedReadinessUri `
                    -TimeoutSeconds $ReadinessTimeoutSeconds
                $job = Update-ReconciledJob -Job (Read-ManagedJob -Path $jobFile)
                $jobOutput = Add-ManagedJobReadiness `
                    -Job (Add-ManagedJobIdentity -Job $job) `
                    -Readiness $readiness
            } catch {
                $readinessFailure = $_.Exception.GetBaseException().Message
                $current = $job
                try { $current = Read-ManagedJob -Path $jobFile } catch {}
                if ($current.status -in @('starting', 'running')) {
                    $terminationRequest = [pscustomobject]@{
                        job = $current
                        reason = 'Stopped because its readiness gate failed.'
                        allowRecordFallback = $true
                    }
                    $termination = @(Stop-ManagedJobTrees -Request @($terminationRequest))[0]
                    if ($termination.error) {
                        throw "$readinessFailure Failed to stop managed job $($current.id): $($termination.error) Managed job log: $($current.logPath)"
                    }
                }
                throw "$readinessFailure Managed job log: $($current.logPath)"
            }
        }
        $jobOutput | ConvertTo-Json -Depth 12
    }
    'list' {
        $jobs = @(Get-ManagedJobsWithActiveReconciliation | Sort-Object createdAtUtc -Descending)
        Write-JobCollection -Jobs (Select-ManagedJobs -Jobs $jobs)
    }
    'status' {
        if ($Id) {
            $job = Read-ManagedJob -Path (Get-ManagedJobFile -Id $Id)
            Add-ManagedJobIdentity -Job (Update-ReconciledJob -Job $job) | ConvertTo-Json -Depth 12
        } else {
            $jobs = @(Get-ManagedJobsWithActiveReconciliation | Sort-Object createdAtUtc -Descending)
            Write-JobCollection -Jobs (Select-ManagedJobs -Jobs $jobs)
        }
    }
    'wait-ready' {
        if (-not $Id) { throw '-Id is required for wait-ready.' }
        if (-not $ReadinessUri) { throw '-ReadinessUri is required for wait-ready.' }
        $resolvedReadinessUri = Resolve-ManagedJobReadinessUri -Uri $ReadinessUri
        $job = Update-ReconciledJob -Job (Read-ManagedJob -Path (Get-ManagedJobFile -Id $Id))
        if ($job.status -notin @('starting', 'running')) {
            throw "Job $Id cannot become ready; current status is $($job.status)."
        }
        $readiness = Wait-ManagedJobReadiness `
            -JobId $Id `
            -Uri $resolvedReadinessUri `
            -TimeoutSeconds $ReadinessTimeoutSeconds
        $job = Update-ReconciledJob -Job (Read-ManagedJob -Path (Get-ManagedJobFile -Id $Id))
        Add-ManagedJobReadiness `
            -Job (Add-ManagedJobIdentity -Job $job) `
            -Readiness $readiness | ConvertTo-Json -Depth 12
    }
    'logs' {
        if (-not $Id) { throw '-Id is required for logs.' }
        $job = Read-ManagedJob -Path (Get-ManagedJobFile -Id $Id)
        if (-not (Test-Path -LiteralPath $job.logPath -PathType Leaf)) {
            throw "Log does not exist yet: $($job.logPath)"
        }
        Get-Content -LiteralPath $job.logPath -Tail $Tail -Wait:$Follow
    }
    'capture' {
        if (-not $Id) { throw '-Id is required for capture.' }
        $context = Get-SharedTerminalContext -JobId $Id
        $captured = Invoke-SharedTerminalCli -Context $context -Arguments @(
            'capture-pane', '--target', $context.sessionId, '--max-lines', [string]$MaxLines
        )
        Write-Output -NoEnumerate $captured
    }
    'send-input' {
        if (-not $Id) { throw '-Id is required for send-input.' }
        if (-not $PSBoundParameters.ContainsKey('InputText')) { throw '-InputText is required for send-input.' }
        Assert-SharedTerminalInputSafe -InputText $InputText
        $context = Get-SharedTerminalContext -JobId $Id
        $null = Invoke-SharedTerminalCli -Context $context -Arguments @(
            'send-keys', '--target', $context.sessionId, '--raw', '--', $InputText
        )
        [pscustomobject]@{
            id = $Id
            action = 'send-input'
            sent = $true
            characterCount = $InputText.Length
        } | ConvertTo-Json
    }
    'send-key' {
        if (-not $Id) { throw '-Id is required for send-key.' }
        if (-not $Key -or $Key.Count -eq 0) { throw '-Key is required for send-key.' }
        $keyTokens = @($Key | ForEach-Object {
            switch ($_) {
                'Enter' { 'Enter' }
                'Tab' { 'Tab' }
                'Escape' { 'Escape' }
                'Backspace' { 'BSpace' }
                'Ctrl+C' { 'C-c' }
            }
        })
        $context = Get-SharedTerminalContext -JobId $Id
        $null = Invoke-SharedTerminalCli -Context $context -Arguments (
            @('send-keys', '--target', $context.sessionId) + $keyTokens
        )
        [pscustomobject]@{
            id = $Id
            action = 'send-key'
            sent = $true
            keyCount = $keyTokens.Count
        } | ConvertTo-Json
    }
    'stop' {
        if (-not $Id) { throw '-Id is required for stop.' }
        $path = Get-ManagedJobFile -Id $Id
        $job = Read-ManagedJob -Path $path
        if ($job.status -notin @('starting', 'running')) {
            throw "Job $Id is not running; current status is $($job.status)."
        }
        $terminationRequest = [pscustomobject]@{
            job = $job
            reason = 'Stopped through managed-jobs.'
        }
        $termination = @(Stop-ManagedJobTrees -Request @($terminationRequest))[0]
        if ($termination.error) { throw [string]$termination.error }
        $job = $termination.job
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
        $matched = 0
        $stopped = @()
        $failures = @()
        $terminationRequests = @()
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
            } catch {
                $failures += [ordered]@{
                    id = $ownerId
                    name = $ownerId
                    hostPid = $null
                    lifetime = $null
                    error = $_.Exception.Message
                }
                continue
            }

            $terminationRequests += [pscustomobject]@{
                job = $job
                reason = "Stopped automatically at the end of its $($job.lifetime) lifetime."
            }
        }
        $terminations = if ($terminationRequests.Count -gt 0) {
            @(Stop-ManagedJobTrees -Request $terminationRequests)
        } else {
            @()
        }
        foreach ($termination in $terminations) {
            $job = $termination.job
            if ($termination.matched) { $matched++ }
            if ($termination.error) {
                $failures += [ordered]@{
                    id = $job.id
                    name = $job.name
                    hostPid = $job.hostPid
                    lifetime = $job.lifetime
                    error = $termination.error
                }
                continue
            }
            $result = $termination.job
            if ($termination.matched -and $result.status -eq 'stopped') {
                $stopped += [ordered]@{
                    id = $result.id
                    name = $result.name
                    hostPid = $result.hostPid
                    lifetime = $result.lifetime
                }
            }
        }
        [ordered]@{
            ownerAgent = $ownerAgentKey
            ownerSessionId = $ownerSessionKey
            lifetimes = $lifetimes
            matched = $matched
            stopped = $stopped
            failures = $failures
        } | ConvertTo-Json -Depth 8
    }
    'reconcile' {
        $maintenanceLock = Enter-ManagedJobMaintenanceLock `
            -Wait:$WaitForMaintenanceLock `
            -TimeoutSeconds $MaintenanceLockWaitSeconds
        try {
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
        } finally {
            $maintenanceLock.Dispose()
        }
    }
    'prune' {
        $maintenanceLock = Enter-ManagedJobMaintenanceLock
        try {
            $plannedCandidateIds = $null
            $skipped = @()
            if ($MaintenancePlan) {
                if ($WhatIfPreference) {
                    throw '-MaintenancePlan cannot be combined with -WhatIf.'
                }
                $plan = Read-PruneMaintenancePlan -Path $MaintenancePlan
                $cutoff = $plan.cutoff
                $statusFilter = $plan.statuses
                $plannedCandidateIds = @($plan.candidateIds)
                $plannedJobs = @()
                foreach ($candidateId in $plannedCandidateIds) {
                    $candidatePath = Get-ManagedJobFile -Id $candidateId
                    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
                        $skipped += [ordered]@{ id = $candidateId; reason = 'record no longer exists or is unreadable' }
                        continue
                    }
                    try {
                        $plannedJobs += Read-ManagedJob -Path $candidatePath
                    } catch {
                        $skipped += [ordered]@{ id = $candidateId; reason = 'record no longer exists or is unreadable' }
                    }
                }
                $candidates = @(Get-PruneCandidates -Jobs $plannedJobs -Cutoff $cutoff -StatusFilter $statusFilter)
                $eligibleIds = @($candidates | ForEach-Object { $_.id })
                foreach ($candidateId in $plannedCandidateIds) {
                    if ($candidateId -notin $eligibleIds -and
                        $candidateId -notin @($skipped | ForEach-Object { $_.id })) {
                        $plannedJob = @($plannedJobs | Where-Object id -eq $candidateId)[0]
                        $timestampText = if ($plannedJob.finishedAtUtc) { $plannedJob.finishedAtUtc } else { $plannedJob.createdAtUtc }
                        $skipped += [ordered]@{
                            id = $candidateId
                            reason = 'record is no longer eligible'
                            status = $plannedJob.status
                            timestampUtc = if ($timestampText -is [datetime]) {
                                $timestampText.ToUniversalTime().ToString('o')
                            } else {
                                [datetimeoffset]::Parse([string]$timestampText).UtcDateTime.ToString('o')
                            }
                        }
                    }
                }
            } else {
                $cutoff = [datetime]::UtcNow.AddDays(-[math]::Abs($OlderThanDays))
                $statusFilter = @($Status)
                $candidates = @(Get-PruneCandidates -Jobs @(Get-AllManagedJobs) -Cutoff $cutoff -StatusFilter $statusFilter)
            }

            $candidateIds = @($candidates | ForEach-Object { $_.id })
            $removed = @()
            foreach ($job in $candidates) {
                if ($PSCmdlet.ShouldProcess($job.id, 'Remove terminal managed-job record and its managed log')) {
                    try { Unregister-ManagedJobOwnerReference -Job $job } catch {}
                    Remove-ManagedJobControl -JobId $job.id
                    $record = Get-ManagedJobFile -Id $job.id
                    $managedLog = Join-Path (Join-Path (Get-ManagedJobRoot) 'logs') "$($job.id).log"
                    if (Test-Path -LiteralPath $managedLog) { Remove-Item -LiteralPath $managedLog -Force }
                    Remove-Item -LiteralPath $record -Force
                    $removed += $job.id
                }
            }
            [pscustomobject]@{
                cutoffUtc = $cutoff.ToString('o')
                selectedStatuses = @($statusFilter)
                plannedCandidateCount = if ($null -ne $plannedCandidateIds) { $plannedCandidateIds.Count } else { $null }
                candidateCount = $candidateIds.Count
                candidates = $candidateIds
                skippedCount = $skipped.Count
                skipped = $skipped
                removedCount = $removed.Count
                removed = $removed
                preview = [bool]$WhatIfPreference
            } | ConvertTo-Json -Depth 5
        } finally {
            $maintenanceLock.Dispose()
        }
    }
}
