[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$controller = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Invoke-ManagedJob.ps1'
$hostScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ManagedJob.Host.ps1'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ManagedJob.Common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('managed-jobs-lifecycle-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $testRoot 'state'
$activeIds = [Collections.Generic.List[string]]::new()
$assertionCount = 0
$previousCodexHome = $env:CODEX_HOME
$previousThreadId = $env:CODEX_THREAD_ID
$previousClaudeHome = $env:CLAUDE_CONFIG_DIR
$previousClaudeSessionId = $env:CLAUDE_CODE_SESSION_ID
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

function Wait-JobStatus {
    param([string]$Id, [string[]]$Expected, [int]$Seconds = 15)
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    do {
        $job = Get-JobStatus -Id $Id
        if ($job.status -in $Expected) { return $job }
        Start-Sleep -Milliseconds 100
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Id to reach $($Expected -join ','); last status was $($job.status)."
}

function Wait-LoggedProcessId {
    param([string]$LogPath, [string]$Pattern, [int]$Seconds = 10)
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    do {
        $log = if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath -Raw } else { '' }
        if ($log -match $Pattern) { return [int]$Matches[1] }
        Start-Sleep -Milliseconds 100
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Timed out waiting for process id pattern '$Pattern' in $LogPath."
}

function Wait-ProcessExit {
    param([int]$TargetProcessId, [int]$Seconds = 10)
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    do {
        if ($null -eq (Get-ProcessSnapshot -ProcessId $TargetProcessId)) { return $true }
        Start-Sleep -Milliseconds 100
    } while ([datetime]::UtcNow -lt $deadline)
    return $false
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

try {
    $null = New-Item -ItemType Directory -Path $stateRoot -Force
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $previousTerminalSession = $env:WT_SESSION
    $env:WT_SESSION = [guid]::NewGuid().ToString('D')
    try {
        $fakeTerminalTools = [pscustomobject]@{ wtcli = $pwsh }
        $withoutSession = Invoke-IntelligentTerminalCliProcess `
            -Tools $fakeTerminalTools `
            -ComClsid ([guid]::NewGuid().ToString('B')) `
            -Arguments @('-NoProfile', '-Command', '[Environment]::GetEnvironmentVariable("WT_SESSION", "Process")')
        Assert-True ([string]::IsNullOrWhiteSpace($withoutSession.standardOutput)) `
            'Non-pane Intelligent Terminal operations should clear an inherited WT_SESSION.'
        $explicitSession = [guid]::NewGuid()
        $withSession = Invoke-IntelligentTerminalCliProcess `
            -Tools $fakeTerminalTools `
            -ComClsid ([guid]::NewGuid().ToString('B')) `
            -SessionId $explicitSession.ToString('D') `
            -Arguments @('-NoProfile', '-Command', '[Environment]::GetEnvironmentVariable("WT_SESSION", "Process")')
        Assert-True ($withSession.standardOutput.Trim() -eq $explicitSession.ToString('D')) `
            'Pane operations should pass only their explicit WT_SESSION.'

        $pipeHolderCommand = @"
`$startInfo = [Diagnostics.ProcessStartInfo]::new('$pwsh')
`$startInfo.UseShellExecute = `$false
`$startInfo.CreateNoWindow = `$true
`$startInfo.ArgumentList.Add('-NoProfile')
`$startInfo.ArgumentList.Add('-Command')
`$startInfo.ArgumentList.Add('Start-Sleep -Seconds 2')
`$grandchild = [Diagnostics.Process]::Start(`$startInfo)
`$grandchild.Dispose()
"@
        $drainTimer = [Diagnostics.Stopwatch]::StartNew()
        $drainTimeoutRejected = $false
        try {
            Invoke-IntelligentTerminalCliProcess `
                -Tools $fakeTerminalTools `
                -ComClsid ([guid]::NewGuid().ToString('B')) `
                -Arguments @('-NoProfile', '-Command', $pipeHolderCommand) `
                -TimeoutSeconds 1 | Out-Null
        } catch {
            $drainTimeoutRejected = $_.Exception.Message -match 'timed out while draining output'
        }
        $drainTimer.Stop()
        Assert-True $drainTimeoutRejected `
            'CLI output draining should remain bounded when a grandchild inherits the pipe.'
        Assert-True ($drainTimer.Elapsed.TotalSeconds -lt 1.75) `
            'CLI output draining should honor the shared controller timeout.'
    } finally {
        if ($null -eq $previousTerminalSession) {
            Remove-Item Env:WT_SESSION -ErrorAction SilentlyContinue
        } else {
            $env:WT_SESSION = $previousTerminalSession
        }
    }
    $testSessionId = 'codex-lifecycle-session'
    $env:CODEX_HOME = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
    $env:CODEX_THREAD_ID = $testSessionId
    Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:CLAUDE_CODE_SESSION_ID -ErrorAction SilentlyContinue
    $env:MANAGED_JOBS_ROOT = $stateRoot
    $null = & $controller reconcile -StateRoot $stateRoot
    $emptyPrunePreview = (& $controller prune -StateRoot $stateRoot -WhatIf | Out-String) | ConvertFrom-Json
    Assert-True (
        $emptyPrunePreview.preview -and
        $emptyPrunePreview.candidateCount -eq 0 -and
        $emptyPrunePreview.removedCount -eq 0
    ) 'Prune preview should accept an empty managed-job registry.'

    $maintenanceLockPath = Join-Path $stateRoot '.maintenance.lock'
    $heldMaintenanceLock = [IO.File]::Open($maintenanceLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $overlappingMaintenanceRejected = $false
        try { & $controller reconcile -StateRoot $stateRoot | Out-Null } catch {
            $overlappingMaintenanceRejected = $_.Exception.Message -match 'maintenance operation is already running'
        }
        Assert-True $overlappingMaintenanceRejected `
            'The maintenance lock should reject overlapping reconcile or prune mutations.'
    } finally {
        $heldMaintenanceLock.Dispose()
    }

    $alternateRoot = Join-Path $testRoot 'alternate-state'
    $alternateTurnRejected = $false
    try {
        & $controller start -StateRoot $alternateRoot -Name 'invisible-to-hooks' -Executable $pwsh | Out-Null
    } catch { $alternateTurnRejected = $_.Exception.Message -match 'hook-visible managed-job state root' }
    Assert-True $alternateTurnRejected 'Automatic lifetimes must reject a state root that Codex cleanup hooks cannot see.'

    # A copied Claude-only skill remains self-contained because scripts resolve companions locally.
    $claudeSkill = Join-Path $testRoot '.claude\skills\managed-jobs'
    Copy-Item -LiteralPath (Split-Path -Parent $PSScriptRoot) -Destination $claudeSkill -Recurse
    $claudeController = Join-Path $claudeSkill 'scripts\Invoke-ManagedJob.ps1'
    $claudeSummary = (& $claudeController reconcile -StateRoot (Join-Path $testRoot 'claude-state') | Out-String) | ConvertFrom-Json
    Assert-True ($claudeSummary.total -eq 0) 'Claude-only copied controller should reconcile without Codex files.'
    $emptyList = @((& $claudeController list -StateRoot (Join-Path $testRoot 'claude-state') -Status running,starting -Json | Out-String) | ConvertFrom-Json)
    Assert-True ($emptyList.Count -eq 0) 'Filtered JSON list should return an empty array when the registry is empty.'
    $emptyStatus = @((& $claudeController status -StateRoot (Join-Path $testRoot 'claude-state') -Status running -Json | Out-String) | ConvertFrom-Json)
    Assert-True ($emptyStatus.Count -eq 0) 'Filtered JSON status should return an empty array when no jobs match.'
    $claudeAuto = (& $claudeController start -StateRoot (Join-Path $testRoot 'claude-state') -Name 'claude-auto' `
        -Executable $pwsh -Arguments @('-NoProfile', '-Command', 'Write-Output claude-auto') | Out-String) | ConvertFrom-Json
    Assert-True ($claudeAuto.lifetime -eq 'persistent' -and -not $claudeAuto.ownerAgent) 'Claude must not adopt inherited Codex turn ownership.'

    # A Claude installation with its own session identity takes Claude turn
    # ownership even while an inherited CODEX_THREAD_ID is still present.
    $claudeSessionId = 'claude-lifecycle-session'
    # The trailing separator proves installation detection normalizes the
    # configured home before comparing it.
    $env:CLAUDE_CONFIG_DIR = (Join-Path $testRoot '.claude') + '\'
    $env:CLAUDE_CODE_SESSION_ID = $claudeSessionId
    $claudeOwned = (& $claudeController start -StateRoot $stateRoot -Name 'claude-owned' `
        -Executable $pwsh -Arguments @('-NoProfile', '-Command', 'Write-Output claude-owned') | Out-String) | ConvertFrom-Json
    $claudeOwned = Wait-JobStatus -Id $claudeOwned.id -Expected @('completed')
    Assert-True ($claudeOwned.ownerAgent -eq 'claude' -and $claudeOwned.ownerSessionId -eq $claudeSessionId) 'A Claude installation should record Claude session ownership.'
    Assert-True ($claudeOwned.lifetime -eq 'turn') 'Claude Auto lifetime should resolve to turn.'
    # CLAUDE_CODE_SESSION_ID stays set from here on so the Codex-installation
    # assertions below also prove the Codex identity is preferred there.

    $hiddenKeepOpenRejected = $false
    try {
        & $controller start -StateRoot $stateRoot -Name 'invalid-hidden-keep-open' -Executable $pwsh -KeepTerminalOpen | Out-Null
    } catch { $hiddenKeepOpenRejected = $_.Exception.Message -match 'requires -Visible' }
    Assert-True $hiddenKeepOpenRejected 'KeepTerminalOpen should require visible execution.'

    $hiddenSharedRejected = $false
    try {
        & $controller start -StateRoot $stateRoot -Name 'invalid-hidden-shared' -Executable $pwsh -SharedTerminal | Out-Null
    } catch { $hiddenSharedRejected = $_.Exception.Message -match 'requires -Visible' }
    Assert-True $hiddenSharedRejected 'SharedTerminal should require visible execution.'

    $backgroundWithoutSharedRejected = $false
    try {
        & $controller start -StateRoot $stateRoot -Name 'invalid-background-without-shared' `
            -Executable $pwsh -Visible -RequireBackgroundTab | Out-Null
    } catch { $backgroundWithoutSharedRejected = $_.Exception.Message -match 'requires -SharedTerminal' }
    Assert-True $backgroundWithoutSharedRejected 'RequireBackgroundTab should require shared-terminal mode.'

    # The host must return instead of propagating the child exit when -NoExit is
    # responsible for keeping a visible terminal open. The durable record retains
    # the real child result.
    $keepOpenId = '20000101-000000-lifecycle-keep-open-000001'
    $keepOpenJobPath = Join-Path $stateRoot "jobs\$keepOpenId.json"
    $keepOpenLaunchPath = Join-Path $stateRoot "launch\$keepOpenId.json"
    $keepOpenJob = [ordered]@{
        schemaVersion = 2; id = $keepOpenId; name = 'lifecycle-keep-open'; kind = 'test'; status = 'starting'; visible = $true
        keepTerminalOpen = $true; createdAtUtc = [datetime]::UtcNow.ToString('o'); startedAtUtc = $null; finishedAtUtc = $null
        hostPid = $null; hostStartedAtUtc = $null; executable = $pwsh; argumentCount = 4; environmentNames = @()
        invocationFingerprint = ('2' * 64); workingDirectory = $testRoot; logPath = (Join-Path $stateRoot "logs\$keepOpenId.log")
        exitCode = $null; error = $null
    }
    $keepOpenLaunch = [ordered]@{ executable = $pwsh; arguments = @('-NoProfile', '-Command', 'exit 17'); environment = @{} }
    $keepOpenJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $keepOpenJobPath -Encoding utf8
    $keepOpenLaunch | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $keepOpenLaunchPath -Encoding utf8
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hostScript -JobFile $keepOpenJobPath -LaunchFile $keepOpenLaunchPath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Keep-open host path should return without propagating the child exit code.'
    $keepOpenResult = Get-JobStatus -Id $keepOpenId
    Assert-True ($keepOpenResult.status -eq 'failed' -and $keepOpenResult.exitCode -eq 17) 'Keep-open record should preserve the real child failure.'

    # The exact encoded command used for a shared-terminal tab must start the
    # shared host, consume the launch file, register terminal metadata, and exit.
    $encodedId = '20000101-000000-lifecycle-encoded-shared-000001'
    $encodedJobPath = Join-Path $stateRoot "jobs\$encodedId.json"
    $encodedLaunchPath = Join-Path $stateRoot "launch\$encodedId.json"
    $encodedJob = [ordered]@{
        schemaVersion = 4; id = $encodedId; name = 'lifecycle-encoded-shared'; kind = 'test'; status = 'starting'
        lifetime = 'persistent'; ownerAgent = $null; ownerSessionId = $null; visible = $true; sharedTerminal = $true
        terminalControlState = 'pending'; terminalLaunchMode = 'foreground-bootstrap'; keepTerminalOpen = $false
        processContainment = 'pending'; createdAtUtc = [datetime]::UtcNow.ToString('o'); startedAtUtc = $null
        finishedAtUtc = $null; hostPid = $null; hostStartedAtUtc = $null; executable = $pwsh; argumentCount = 3
        environmentNames = @(); invocationFingerprint = ('5' * 64); workingDirectory = $testRoot
        logPath = (Join-Path $stateRoot "logs\$encodedId.log"); exitCode = $null; error = $null
    }
    $encodedLaunch = [ordered]@{
        executable = $pwsh
        arguments = @('-NoProfile', '-Command', 'Write-Output encoded-shared-ok')
        environment = @{}
    }
    $encodedJob | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $encodedJobPath -Encoding utf8
    $encodedLaunch | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $encodedLaunchPath -Encoding utf8
    $savedWtSession = $env:WT_SESSION
    $savedWtComClsid = $env:WT_COM_CLSID
    try {
        $env:WT_SESSION = [guid]::NewGuid().ToString('D')
        $env:WT_COM_CLSID = [guid]::NewGuid().ToString('B')
        $encodedArguments = Get-ManagedJobHostPowerShellArguments `
            -HostScript $hostScript `
            -JobFile $encodedJobPath `
            -LaunchFile $encodedLaunchPath
        $encodedOutput = (& $pwsh @encodedArguments 2>&1 | Out-String)
        Assert-True ($LASTEXITCODE -eq 0) 'Encoded shared-host invocation should exit successfully.'
    } finally {
        if ($null -eq $savedWtSession) { Remove-Item Env:WT_SESSION -ErrorAction SilentlyContinue } else { $env:WT_SESSION = $savedWtSession }
        if ($null -eq $savedWtComClsid) { Remove-Item Env:WT_COM_CLSID -ErrorAction SilentlyContinue } else { $env:WT_COM_CLSID = $savedWtComClsid }
    }
    $encodedResult = Get-JobStatus -Id $encodedId
    Assert-True (
        $encodedResult.status -eq 'completed' -and
        $encodedResult.terminalControlState -eq 'released'
    ) 'Encoded shared-host invocation should preserve its completed lifecycle state.'
    Assert-True ($encodedOutput -match 'encoded-shared-ok') `
        'Encoded shared-host invocation should run the managed child.'
    Assert-True (-not (Test-Path -LiteralPath $encodedLaunchPath)) `
        'Encoded shared-host invocation should consume the launch handoff.'

    # A cold-start shared-terminal reservation (starting, no host yet) must
    # survive reconciliation through the bootstrap worst case, while ordinary
    # pre-host records keep the 30-second stale threshold.
    function New-ReservationRecord {
        param([string]$Id, [int]$AgeSeconds, [string]$LaunchMode)
        $record = [ordered]@{
            schemaVersion = 4; id = $Id; name = $Id; kind = 'test'; status = 'starting'
            lifetime = 'persistent'; ownerAgent = $null; ownerSessionId = $null; visible = $true
            keepTerminalOpen = $false; processContainment = 'pending'
            createdAtUtc = [datetime]::UtcNow.AddSeconds(-$AgeSeconds).ToString('o')
            startedAtUtc = $null; finishedAtUtc = $null; hostPid = $null; hostStartedAtUtc = $null
            executable = $pwsh; argumentCount = 0; environmentNames = @()
            invocationFingerprint = ('7' * 64); workingDirectory = $testRoot
            logPath = (Join-Path $stateRoot "logs\$Id.log"); exitCode = $null; error = $null
        }
        if ($LaunchMode) {
            $record['sharedTerminal'] = $true
            $record['terminalControlState'] = 'pending'
            $record['terminalLaunchMode'] = $LaunchMode
        }
        $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot "jobs\$Id.json") -Encoding utf8
    }
    New-ReservationRecord -Id '20000101-000000-reserve-bootstrap-fresh-000001' -AgeSeconds 150 -LaunchMode 'foreground-bootstrap'
    New-ReservationRecord -Id '20000101-000000-reserve-bootstrap-expired-000001' -AgeSeconds 190 -LaunchMode 'foreground-bootstrap'
    New-ReservationRecord -Id '20000101-000000-reserve-plain-expired-000001' -AgeSeconds 60 -LaunchMode $null
    Assert-True ((Get-JobStatus -Id '20000101-000000-reserve-bootstrap-fresh-000001').status -eq 'starting') `
        'A cold-start reservation inside the bootstrap allowance must survive reconciliation.'
    Assert-True ((Get-JobStatus -Id '20000101-000000-reserve-bootstrap-expired-000001').status -eq 'orphaned') `
        'A cold-start reservation beyond the bootstrap allowance should be orphaned.'
    Assert-True ((Get-JobStatus -Id '20000101-000000-reserve-plain-expired-000001').status -eq 'orphaned') `
        'An ordinary pre-host record keeps the 30-second stale threshold.'
    foreach ($reservationId in @(
        '20000101-000000-reserve-bootstrap-fresh-000001',
        '20000101-000000-reserve-bootstrap-expired-000001',
        '20000101-000000-reserve-plain-expired-000001'
    )) {
        Remove-Item -LiteralPath (Join-Path $stateRoot "jobs\$reservationId.json") -Force
    }

    # Normal startup and collection inspection reconcile only active records;
    # explicit reconciliation retains full historical cleanup behavior.
    $historicalId = '20000101-000000-lifecycle-historical-000001'
    $historicalRecord = [ordered]@{
        schemaVersion = 4; id = $historicalId; name = 'lifecycle-historical'; kind = 'test'; status = 'completed'
        lifetime = 'turn'; ownerAgent = 'codex'; ownerSessionId = $testSessionId; visible = $true; sharedTerminal = $true
        terminalControlState = 'released'; keepTerminalOpen = $false; processContainment = 'windows-job-object-kill-on-close'
        createdAtUtc = '2000-01-01T00:00:00Z'; startedAtUtc = '2000-01-01T00:00:01Z'; finishedAtUtc = '2000-01-01T00:00:02Z'
        hostPid = 2147483647; hostStartedAtUtc = '2000-01-01T00:00:01Z'; executable = 'fixture'; argumentCount = 0
        environmentNames = @(); invocationFingerprint = ('8' * 64); workingDirectory = $testRoot
        logPath = (Join-Path $stateRoot "logs\$historicalId.log"); exitCode = 0; error = $null
    }
    $historicalPath = Join-Path $stateRoot "jobs\$historicalId.json"
    $historicalControlPath = Get-ManagedJobControlFile -Id $historicalId
    $historicalRecord | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $historicalPath -Encoding utf8
    Register-ManagedJobOwnerReference -Job ([pscustomobject]$historicalRecord)
    @{ schemaVersion = 1; jobId = $historicalId; hostPid = 2147483647; wtSession = [guid]::NewGuid(); wtComClsid = [guid]::NewGuid() } |
        ConvertTo-Json | Set-Content -LiteralPath $historicalControlPath -Encoding utf8

    # Start, record redaction, structured list/status, logs, and reconcile.
    $completed = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-complete' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Write-Output lifecycle-ok') -Environment @{ LIFECYCLE_MARKER = 'not-recorded'; GIT_AUTHOR_NAME = 'Lifecycle Test' } | Out-String) | ConvertFrom-Json
    $completed = Wait-JobStatus -Id $completed.id -Expected @('completed')
    Assert-True (Test-Path -LiteralPath $historicalControlPath) `
        'Normal startup must not reconcile inactive historical control records.'
    Assert-True (@(Get-ManagedJobOwnerReferenceIds -OwnerAgent codex -OwnerSessionId $testSessionId -Lifetime turn) -contains $historicalId) `
        'Normal startup must not reconcile inactive historical owner references.'
    $null = & $controller list -StateRoot $stateRoot -Status running,starting -Json
    Assert-True (Test-Path -LiteralPath $historicalControlPath) `
        'Collection listing must not reconcile inactive historical control records.'
    $null = & $controller reconcile -StateRoot $stateRoot -Status completed
    Assert-True (-not (Test-Path -LiteralPath $historicalControlPath)) `
        'Explicit reconciliation should clean inactive historical control records.'
    Assert-True (@(Get-ManagedJobOwnerReferenceIds -OwnerAgent codex -OwnerSessionId $testSessionId -Lifetime turn) -notcontains $historicalId) `
        'Explicit reconciliation should clean inactive historical owner references.'
    Remove-Item -LiteralPath $historicalPath -Force
    $recordText = Get-Content -LiteralPath (Join-Path $stateRoot "jobs\$($completed.id).json") -Raw
    Assert-True ($recordText -notmatch 'lifecycle-ok|not-recorded|Lifecycle Test') 'Permanent records must omit argument text and environment values.'
    Assert-True ($completed.schemaVersion -eq 3) 'Existing start callers should retain schema version 3.'
    Assert-True ($completed.PSObject.Properties.Name -notcontains 'sharedTerminal') `
        'Existing start callers should retain their durable record shape.'
    Assert-True ($completed.ownerAgent -eq 'codex' -and $completed.ownerSessionId -eq $testSessionId) 'Codex records should capture their owning session even when a Claude session id is inherited.'
    Assert-True ($completed.lifetime -eq 'turn') 'Codex Auto lifetime should resolve to turn.'
    Assert-True ($completed.processContainment -eq 'windows-job-object-kill-on-close') 'Managed hosts should enable Windows process-tree containment.'
    $completedReferences = @(Get-ManagedJobOwnerReferenceIds -OwnerAgent codex -OwnerSessionId $testSessionId -Lifetime turn)
    Assert-True ($completedReferences -notcontains $completed.id) 'A completed job should remove its active owner reference.'
    $logText = (& $controller logs -Id $completed.id -StateRoot $stateRoot -Tail 20 | Out-String)
    Assert-True ($logText -match 'lifecycle-ok') 'Logs should capture child output.'
    Assert-True ($logText -notmatch 'Write-Output lifecycle-ok|LIFECYCLE_MARKER|not-recorded') 'Controller log metadata must omit arguments and environment.'
    $completedList = @((& $controller list -StateRoot $stateRoot -Status completed -Json | Out-String) | ConvertFrom-Json)
    Assert-True ($completedList.id -contains $completed.id) 'Structured list filter should return the completed job.'
    $completedStatus = @((& $controller status -StateRoot $stateRoot -Status completed -Json | Out-String) | ConvertFrom-Json)
    Assert-True ($completedStatus.id -contains $completed.id) 'Structured status filter should return the completed job.'

    # Readiness probes accept only credential-free loopback HTTP(S) URLs and
    # must reject invalid targets before creating a durable record.
    $beforeReadinessValidation = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'jobs') -File).Count
    foreach ($invalidReadinessUri in @(
        [uri]'health',
        [uri]'https://example.com/health',
        [uri]'http://127.0.0.1:12345/health?token=do-not-store',
        [uri]'http://user:password@127.0.0.1:12345/health',
        [uri]'http://127.0.0.1:12345/health#credential'
    )) {
        $invalidReadinessRejected = $false
        try {
            & $controller start -StateRoot $stateRoot -Name 'invalid-readiness' -Executable $pwsh `
                -ReadinessUri $invalidReadinessUri | Out-Null
        } catch { $invalidReadinessRejected = $_.Exception.Message -match 'ReadinessUri' }
        Assert-True $invalidReadinessRejected "Invalid readiness URI should be rejected: $invalidReadinessUri"
    }
    $orphanedTimeoutRejected = $false
    try {
        & $controller start -StateRoot $stateRoot -Name 'invalid-readiness-timeout' -Executable $pwsh `
            -ReadinessTimeoutSeconds 1 | Out-Null
    } catch { $orphanedTimeoutRejected = $_.Exception.Message -match 'requires -ReadinessUri' }
    Assert-True $orphanedTimeoutRejected 'A readiness timeout without a readiness URI should be rejected.'
    $wrongActionRoot = Join-Path $testRoot 'wrong-action-state'
    $wrongActionReadinessRejected = $false
    try {
        & $controller list -StateRoot $wrongActionRoot -ReadinessUri ([uri]'http://127.0.0.1:12345/health') | Out-Null
    } catch { $wrongActionReadinessRejected = $_.Exception.Message -match 'valid only for start and wait-ready' }
    Assert-True $wrongActionReadinessRejected 'Readiness parameters should be rejected for unrelated actions.'
    Assert-True (-not (Test-Path -LiteralPath $wrongActionRoot)) `
        'Readiness parameter misuse should fail before the state root is created.'
    Assert-True (
        @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'jobs') -File).Count -eq $beforeReadinessValidation
    ) 'Rejected readiness URIs must not create records.'

    $completedReadinessRejected = $false
    try {
        & $controller wait-ready -StateRoot $stateRoot -Id $completed.id `
            -ReadinessUri ([uri]'http://127.0.0.1:12345/health') | Out-Null
    } catch { $completedReadinessRejected = $_.Exception.Message -match 'current status is completed' }
    Assert-True $completedReadinessRejected 'wait-ready should reject a terminal managed job.'

    $exitingPort = Get-FreeTcpPort
    $exitingReadinessRejected = $false
    try {
        & $controller start -StateRoot $stateRoot -Name 'lifecycle-readiness-exits' -Executable $pwsh `
            -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Milliseconds 300') `
            -ReadinessUri ([uri]"http://127.0.0.1:$exitingPort/health") -ReadinessTimeoutSeconds 3 | Out-Null
    } catch { $exitingReadinessRejected = $_.Exception.Message -match "reached status '(completed|failed)'" }
    Assert-True $exitingReadinessRejected 'A job that exits during probing should fail before the readiness deadline.'

    # A concurrently removed record must not prevent start from terminating the
    # process tree that this invocation owns after its readiness gate fails.
    $recordLossPort = Get-FreeTcpPort
    $recordLossCommand = @"
Write-Output "readiness-record-loss-child-pid=`$PID"
Start-Sleep -Milliseconds 750
`$record = Get-ChildItem -LiteralPath '$stateRoot\jobs' -Filter '*.json' -File | Where-Object {
    try { (Get-Content -LiteralPath `$_ -Raw | ConvertFrom-Json).name -eq 'lifecycle-readiness-record-loss' } catch { `$false }
} | Select-Object -First 1
if (`$record) { Remove-Item -LiteralPath `$record.FullName -Force }
Start-Sleep -Seconds 30
"@
    $recordLossError = $null
    try {
        & $controller start -StateRoot $stateRoot -Name 'lifecycle-readiness-record-loss' -Executable $pwsh `
            -Arguments @('-NoProfile', '-Command', $recordLossCommand) `
            -ReadinessUri ([uri]"http://127.0.0.1:$recordLossPort/health") -ReadinessTimeoutSeconds 5 | Out-Null
    } catch { $recordLossError = $_.Exception.Message }
    Assert-True ($recordLossError -match 'Managed job record not found') `
        "A missing owned-job record should preserve the readiness failure. Error: $recordLossError"
    $recordLossLog = Get-ChildItem -LiteralPath (Join-Path $stateRoot 'logs') `
        -Filter '*-lifecycle-readiness-record-loss-*.log' -File | Select-Object -First 1
    $recordLossChildPid = Wait-LoggedProcessId -LogPath $recordLossLog.FullName `
        -Pattern 'readiness-record-loss-child-pid=(\d+)'
    Assert-True (Wait-ProcessExit -TargetProcessId $recordLossChildPid) `
        'Readiness failure cleanup should terminate its owned process even when the record disappears.'

    # A delayed loopback HTTP server proves that start waits for application
    # readiness and that a reused running job can be checked independently.
    $readyPort = Get-FreeTcpPort
    $readyUri = [uri]"http://127.0.0.1:$readyPort/health"
    $serverCommand = @"
Start-Sleep -Milliseconds 350
`$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $readyPort)
`$listener.Start()
Write-Output "readiness-server-pid=`$PID"
`$requestCount = 0
while (`$true) {
    `$client = `$listener.AcceptTcpClient()
    try {
        `$stream = `$client.GetStream()
        `$buffer = [byte[]]::new(1024)
        `$null = `$stream.Read(`$buffer, 0, `$buffer.Length)
        `$crlf = [string][char]13 + [char]10
        `$requestCount++
        if (`$requestCount -eq 1) {
            `$responseText = "HTTP/1.1 503 Service Unavailable`$crlf" + "Content-Length: 0`$crlf" + "Connection: close`$crlf`$crlf"
        } elseif (`$requestCount -eq 2) {
            `$responseText = "HTTP/1.1 302 Found`$crlf" + "Location: http://127.0.0.1:1/unreachable`$crlf" + "Content-Length: 0`$crlf" + "Connection: close`$crlf`$crlf"
        } else {
            `$responseText = "HTTP/1.1 204 No Content`$crlf" + "Content-Length: 0`$crlf" + "Connection: close`$crlf`$crlf"
        }
        `$response = [Text.Encoding]::ASCII.GetBytes(`$responseText)
        `$stream.Write(`$response, 0, `$response.Length)
    } finally {
        `$client.Dispose()
    }
}
"@
    $readyJob = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-readiness' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', $serverCommand) -ReadinessUri $readyUri `
        -ReadinessTimeoutSeconds 5 | Out-String) | ConvertFrom-Json
    $activeIds.Add($readyJob.id)
    Assert-True ($readyJob.status -eq 'running') 'A ready long-running service should remain running.'
    Assert-True (
        $readyJob.readiness.status -eq 'ready' -and
        $readyJob.readiness.httpStatusCode -eq 302 -and
        $readyJob.readiness.attempts -ge 2
    ) 'Start should retry a 503, accept a redirect without following it, and return readiness evidence.'
    $reusedReadyJob = (& $controller wait-ready -StateRoot $stateRoot -Id $readyJob.id `
        -ReadinessUri $readyUri -ReadinessTimeoutSeconds 2 | Out-String) | ConvertFrom-Json
    Assert-True ($reusedReadyJob.id -eq $readyJob.id -and $reusedReadyJob.readiness.status -eq 'ready') `
        'wait-ready should verify an existing managed job without replacing it.'
    $unreadyPort = Get-FreeTcpPort
    $reusedReadinessRejected = $false
    try {
        & $controller wait-ready -StateRoot $stateRoot -Id $readyJob.id `
            -ReadinessUri ([uri]"http://127.0.0.1:$unreadyPort/health") -ReadinessTimeoutSeconds 1 | Out-Null
    } catch { $reusedReadinessRejected = $_.Exception.Message -match 'was not ready' }
    Assert-True $reusedReadinessRejected 'wait-ready should report a readiness timeout.'
    Assert-True ((Get-JobStatus -Id $readyJob.id).status -eq 'running') `
        'A failed wait-ready probe must leave an existing managed job running.'
    $null = & $controller stop -StateRoot $stateRoot -Id $readyJob.id
    $activeIds.Remove($readyJob.id) | Out-Null

    # A listener that accepts but never answers proves the per-probe budget is
    # clamped to the overall readiness deadline and reports a useful diagnostic.
    $hangingPort = Get-FreeTcpPort
    $hangingUri = [uri]"http://127.0.0.1:$hangingPort/health"
    $hangingServerCommand = @"
`$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $hangingPort)
`$listener.Start()
Write-Output "hanging-readiness-server-pid=`$PID"
`$client = `$listener.AcceptTcpClient()
try { Start-Sleep -Seconds 30 } finally { `$client.Dispose(); `$listener.Stop() }
"@
    $hangingJob = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-readiness-hangs' `
        -Executable $pwsh -Arguments @('-NoProfile', '-Command', $hangingServerCommand) | Out-String) | ConvertFrom-Json
    $activeIds.Add($hangingJob.id)
    $null = Wait-LoggedProcessId -LogPath $hangingJob.logPath -Pattern 'hanging-readiness-server-pid=(\d+)'
    $hangingTimer = [Diagnostics.Stopwatch]::StartNew()
    $hangingReadinessError = $null
    try {
        & $controller wait-ready -StateRoot $stateRoot -Id $hangingJob.id `
            -ReadinessUri $hangingUri -ReadinessTimeoutSeconds 3 | Out-Null
    } catch { $hangingReadinessError = $_.Exception.Message }
    $hangingTimer.Stop()
    Assert-True ($hangingReadinessError -match 'probe exceeded its response budget') `
        "A hanging readiness endpoint should report its probe budget. Error: $hangingReadinessError"
    Assert-True ($hangingTimer.Elapsed.TotalSeconds -lt 4) `
        "A hanging probe should honor the overall deadline. Elapsed: $($hangingTimer.Elapsed.TotalSeconds) seconds."
    $null = & $controller stop -StateRoot $stateRoot -Id $hangingJob.id
    $activeIds.Remove($hangingJob.id) | Out-Null

    # A failed start-time readiness gate stops only the job started by that
    # invocation and leaves a durable explanation.
    $timeoutPort = Get-FreeTcpPort
    $timeoutUri = [uri]"http://[::1]:$timeoutPort/health"
    $readinessTimeoutRejected = $false
    try {
        & $controller start -StateRoot $stateRoot -Name 'lifecycle-readiness-timeout' -Executable $pwsh `
            -Arguments @('-NoProfile', '-Command', 'Write-Output "readiness-timeout-child-pid=$PID"; Start-Sleep -Seconds 30') `
            -ReadinessUri $timeoutUri -ReadinessTimeoutSeconds 1 | Out-Null
    } catch { $readinessTimeoutRejected = $_.Exception.Message -match 'was not ready' }
    Assert-True $readinessTimeoutRejected 'Start should fail when its readiness deadline expires.'
    $timeoutJob = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'jobs') -File | ForEach-Object {
        Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
    } | Where-Object name -eq 'lifecycle-readiness-timeout')[0]
    Assert-True ($timeoutJob.status -eq 'stopped' -and $timeoutJob.error -match 'readiness gate failed') `
        'A readiness timeout should stop the new managed job and preserve the reason.'
    $timeoutChildPid = Wait-LoggedProcessId -LogPath $timeoutJob.logPath -Pattern 'readiness-timeout-child-pid=(\d+)'
    Assert-True (Wait-ProcessExit -TargetProcessId $timeoutChildPid) `
        'Readiness failure cleanup should terminate the managed process tree.'

    # Secret-looking values are rejected before a record or launch artifact is created.
    $beforeSecretCheck = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'jobs') -File).Count
    $secretRejected = $false
    try {
        & $controller start -StateRoot $stateRoot -Name rejected -Executable $pwsh -Environment @{ API_TOKEN = 'do-not-store' } | Out-Null
    } catch { $secretRejected = $_.Exception.Message -match 'secret-bearing' }
    Assert-True $secretRejected 'Secret-like environment keys should be rejected.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'jobs') -File).Count -eq $beforeSecretCheck) 'Rejected launches must not create records.'
    $argumentSecretRejected = $false
    try {
        & $controller start -StateRoot $stateRoot -Name rejected -Executable $pwsh -Arguments @('--api-token', 'do-not-store') | Out-Null
    } catch { $argumentSecretRejected = $_.Exception.Message -match 'secret-bearing' }
    Assert-True $argumentSecretRejected 'Secret-like argument options should be rejected.'
    foreach ($safeArguments in @(@('--cookie', './cookies.txt'), @('--pwd', './dump.sql'), @('--auth', 'basic'))) {
        $safeAccepted = $true
        try { Assert-SecretSafeInvocation -Arguments $safeArguments -Environment @{} } catch { $safeAccepted = $false }
        Assert-True $safeAccepted "Benign option should not be rejected: $($safeArguments -join ' ')"
    }
    $nullArgumentsAccepted = $true
    try { Assert-SecretSafeInvocation -Arguments $null -Environment @{} } catch { $nullArgumentsAccepted = $false }
    Assert-True $nullArgumentsAccepted 'An explicitly null argument array should be treated as empty.'
    foreach ($secretKey in @('DBPASSWORD', 'CLIENTSECRET', 'MYAPITOKEN', 'MY-SECRET')) {
        $secretNameRejected = $false
        try { Assert-SecretSafeInvocation -Arguments @() -Environment @{ $secretKey = 'do-not-store' } } catch { $secretNameRejected = $true }
        Assert-True $secretNameRejected "Secret-like environment key should be rejected: $secretKey"
    }
    foreach ($safeKey in @('PASSWORD_MIN_LENGTH', 'COOKIE_DOMAIN', 'TOKEN_BUCKET_SIZE', 'CSRF_TOKEN_HEADER')) {
        $safeAccepted = $true
        try { Assert-SecretSafeInvocation -Arguments @() -Environment @{ $safeKey = 'configuration' } } catch { $safeAccepted = $false }
        Assert-True $safeAccepted "Benign environment key should not be rejected: $safeKey"
    }
    foreach ($terminalSecretInput in @(
        'api-token=do-not-send',
        'tool --password do-not-send',
        'git clone https://user:do-not-send@example.invalid/repository.git'
    )) {
        $terminalSecretRejected = $false
        try { Assert-SharedTerminalInputSafe -InputText $terminalSecretInput } catch { $terminalSecretRejected = $true }
        Assert-True $terminalSecretRejected `
            'Shared-terminal input should reject likely credential material anywhere in the command line.'
    }
    $terminalMarkerAccepted = $true
    try { Assert-SharedTerminalInputSafe -InputText 'run-safe-marker' } catch { $terminalMarkerAccepted = $false }
    Assert-True $terminalMarkerAccepted 'Shared-terminal input should accept ordinary non-secret literal text.'
    $firstFingerprint = Get-InvocationFingerprint -Executable $pwsh -Arguments @('-NoProfile') -WorkingDirectory (Get-Location).Path -Environment @{ PORT = '3000' }
    $secondFingerprint = Get-InvocationFingerprint -Executable $pwsh -Arguments @('-NoProfile') -WorkingDirectory (Get-Location).Path -Environment @{ PORT = '4000' }
    Assert-True ($firstFingerprint -ne $secondFingerprint) 'Environment values should distinguish invocation fingerprints.'

    $cmdletJob = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-cmdlet' -Executable 'Write-Output' -Arguments @('lifecycle-cmdlet') | Out-String) | ConvertFrom-Json
    $cmdletJob = Wait-JobStatus -Id $cmdletJob.id -Expected @('completed', 'failed')
    Assert-True ($cmdletJob.status -eq 'completed') 'PowerShell commands without LASTEXITCODE should complete successfully.'

    $emptyId = '20000101-000000-lifecycle-empty-000001'
    $emptyPath = Join-Path $stateRoot "jobs\$emptyId.json"
    Set-Content -LiteralPath $emptyPath -Value '' -Encoding utf8
    $emptyRejected = $false
    try { & $controller status -StateRoot $stateRoot -Id $emptyId | Out-Null } catch { $emptyRejected = $_.Exception.Message -match 'record is empty' }
    Assert-True $emptyRejected 'Empty records should fail with an explicit error.'
    Remove-Item -LiteralPath $emptyPath -Force

    $invalidNamePath = Join-Path $stateRoot 'jobs\invalid job name.json'
    Set-Content -LiteralPath $invalidNamePath -Value '{' -Encoding utf8
    $invalidJobs = @((& $controller status -StateRoot $stateRoot -Status invalid -Json | Out-String) | ConvertFrom-Json)
    Assert-True ($invalidJobs.id -contains 'invalid job name') `
        'Invalid records with non-id-shaped filenames must not break reconciliation or listing.'
    Remove-Item -LiteralPath $invalidNamePath -Force

    # A fresh unclaimed starting record remains active during its startup grace period.
    $freshId = '20000101-000000-lifecycle-starting-000001'
    $freshArguments = @('-NoProfile', '-Command', 'Start-Sleep -Seconds 29')
    $freshFingerprint = Get-InvocationFingerprint -Executable $pwsh -Arguments $freshArguments -WorkingDirectory (Get-Location).Path -Environment @{}
    $freshRecord = [ordered]@{
        schemaVersion = 2; id = $freshId; name = 'lifecycle-starting'; kind = 'test'; status = 'starting'; visible = $false
        keepTerminalOpen = $false; createdAtUtc = [datetime]::UtcNow.ToString('o'); startedAtUtc = $null; finishedAtUtc = $null
        hostPid = $null; hostStartedAtUtc = $null; executable = $pwsh; argumentCount = $freshArguments.Count; environmentNames = @()
        invocationFingerprint = $freshFingerprint; workingDirectory = (Get-Location).Path; logPath = (Join-Path $stateRoot "logs\$freshId.log")
        exitCode = $null; error = $null
    }
    $freshRecord | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot "jobs\$freshId.json") -Encoding utf8
    $freshDuplicateRejected = $false
    $freshError = $null
    try {
        & $controller start -StateRoot $stateRoot -Name 'lifecycle-starting-duplicate' -Executable $pwsh -Arguments $freshArguments | Out-Null
    } catch { $freshError = $_.Exception.Message; $freshDuplicateRejected = $freshError -match [regex]::Escape($freshId) }
    Assert-True $freshDuplicateRejected "Fresh unclaimed starting records must block equivalent launches. Error: $freshError"
    Assert-True ((Get-JobStatus -Id $freshId).status -eq 'starting') 'Fresh unclaimed starting record must not reconcile to orphaned.'
    Remove-Item -LiteralPath (Join-Path $stateRoot "jobs\$freshId.json") -Force

    # Duplicate detection happens while the first equivalent helper is active.
    $running = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-running' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Write-Output "explicit-stop-child-pid=$PID"; Start-Sleep -Seconds 30') | Out-String) | ConvertFrom-Json
    $activeIds.Add($running.id)
    $running = Wait-JobStatus -Id $running.id -Expected @('running')
    $explicitStopChildPid = Wait-LoggedProcessId -LogPath $running.logPath -Pattern 'explicit-stop-child-pid=(\d+)'
    $duplicateRejected = $false
    try {
        & $controller start -StateRoot $stateRoot -Name 'lifecycle-duplicate' -Executable $pwsh `
            -Arguments @('-NoProfile', '-Command', 'Write-Output "explicit-stop-child-pid=$PID"; Start-Sleep -Seconds 30') | Out-Null
    } catch { $duplicateRejected = $_.Exception.Message -match [regex]::Escape($running.id) }
    Assert-True $duplicateRejected 'Equivalent active launch should be rejected with the existing id.'
    $stopped = (& $controller stop -StateRoot $stateRoot -Id $running.id | Out-String) | ConvertFrom-Json
    $activeIds.Remove($running.id) | Out-Null
    Assert-True ($stopped.status -eq 'stopped') 'Stop should record a stopped terminal state.'
    Assert-True ($stopped.PSObject.Properties.Name -notcontains 'processIdentity') 'Terminal jobs should not inspect potentially reused PIDs.'
    Assert-True (Wait-ProcessExit -TargetProcessId $explicitStopChildPid) 'Explicit stop should terminate the managed child through Job Object containment.'

    # Turn cleanup stops only matching Codex-owned work.
    $turnOwned = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-turn-owned' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Write-Output "cleanup-child-pid=$PID"; Start-Sleep -Seconds 30') | Out-String) | ConvertFrom-Json
    $activeIds.Add($turnOwned.id)
    $turnOwned = Wait-JobStatus -Id $turnOwned.id -Expected @('running')
    $cleanupChildPid = Wait-LoggedProcessId -LogPath $turnOwned.logPath -Pattern 'cleanup-child-pid=(\d+)'
    $turnSummary = (& $controller cleanup -StateRoot $stateRoot -OwnerAgent codex -OwnerSessionId $testSessionId -CleanupLifetime Turn | Out-String) | ConvertFrom-Json
    Assert-True ($turnSummary.stopped.id -contains $turnOwned.id) 'Turn cleanup should report the stopped owned process.'
    $activeIds.Remove($turnOwned.id) | Out-Null
    Assert-True ((Get-JobStatus -Id $turnOwned.id).status -eq 'stopped') 'The Codex Stop hook should stop a matching turn-owned process tree.'
    Assert-True (Wait-ProcessExit -TargetProcessId $cleanupChildPid) 'Automatic cleanup should terminate the managed child through Job Object containment.'
    $turnReferences = @(Get-ManagedJobOwnerReferenceIds -OwnerAgent codex -OwnerSessionId $testSessionId -Lifetime turn)
    Assert-True ($turnReferences -notcontains $turnOwned.id) 'Turn cleanup should remove the stopped job owner reference.'

    $otherOwned = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-other-session' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -Lifetime Turn `
        -OwnerAgent codex -OwnerSessionId 'another-session' | Out-String) | ConvertFrom-Json
    $activeIds.Add($otherOwned.id)
    $otherOwned = Wait-JobStatus -Id $otherOwned.id -Expected @('running')
    $ignoredSummary = (& $controller cleanup -StateRoot $stateRoot -OwnerAgent codex -OwnerSessionId $testSessionId -CleanupLifetime Turn | Out-String) | ConvertFrom-Json
    Assert-True ($ignoredSummary.matched -eq 0) 'Cleanup must ignore a process owned by another session.'
    Assert-True ((Get-JobStatus -Id $otherOwned.id).status -eq 'running') 'An unrelated session process must remain running.'
    $null = & $controller stop -StateRoot $stateRoot -Id $otherOwned.id
    $activeIds.Remove($otherOwned.id) | Out-Null

    $persistent = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-persistent' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -Lifetime Persistent | Out-String) | ConvertFrom-Json
    $activeIds.Add($persistent.id)
    $persistent = Wait-JobStatus -Id $persistent.id -Expected @('running')
    $persistentSummary = (& $controller cleanup -StateRoot $stateRoot -OwnerAgent codex -OwnerSessionId $testSessionId -CleanupLifetime Turn,Session | Out-String) | ConvertFrom-Json
    Assert-True ($persistentSummary.matched -eq 0) 'Automatic cleanup must ignore explicitly persistent work.'
    Assert-True ((Get-JobStatus -Id $persistent.id).status -eq 'running') 'Persistent work should survive automatic cleanup.'
    $null = & $controller stop -StateRoot $stateRoot -Id $persistent.id
    $activeIds.Remove($persistent.id) | Out-Null

    $sessionOwned = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-session-owned' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -Lifetime Session | Out-String) | ConvertFrom-Json
    $activeIds.Add($sessionOwned.id)
    $sessionOwned = Wait-JobStatus -Id $sessionOwned.id -Expected @('running')
    $sessionSummary = (& $controller cleanup -StateRoot $stateRoot -OwnerAgent codex -OwnerSessionId $testSessionId -CleanupLifetime Turn,Session | Out-String) | ConvertFrom-Json
    Assert-True ($sessionSummary.stopped.id -contains $sessionOwned.id) 'Session cleanup should report the stopped owned process.'
    $activeIds.Remove($sessionOwned.id) | Out-Null
    Assert-True ((Get-JobStatus -Id $sessionOwned.id).status -eq 'stopped') 'The Codex SessionEnd hook should stop session-owned work.'

    $unrelatedStaleId = '20000101-000000-lifecycle-unrelated-stale-000001'
    $unrelatedStaleRecord = [ordered]@{
        schemaVersion = 3; id = $unrelatedStaleId; name = 'lifecycle-unrelated-stale'; kind = 'test'; status = 'running'
        lifetime = 'turn'; ownerAgent = 'codex'; ownerSessionId = 'another-session'; visible = $false; keepTerminalOpen = $false
        processContainment = 'windows-job-object-kill-on-close'; createdAtUtc = '2000-01-01T00:00:00Z'
        startedAtUtc = '2000-01-01T00:00:01Z'; finishedAtUtc = $null; hostPid = 2147483647
        hostStartedAtUtc = '2000-01-01T00:00:01Z'; executable = 'fixture'; argumentCount = 0; environmentNames = @()
        invocationFingerprint = ('4' * 64); workingDirectory = $testRoot; logPath = (Join-Path $stateRoot "logs\$unrelatedStaleId.log")
        exitCode = $null; error = $null
    }
    $unrelatedStaleRecord | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot "jobs\$unrelatedStaleId.json") -Encoding utf8
    Register-ManagedJobOwnerReference -Job ([pscustomobject]$unrelatedStaleRecord)
    $null = & $controller cleanup -StateRoot $stateRoot -OwnerAgent codex -OwnerSessionId $testSessionId -CleanupLifetime Turn
    $unrelatedAfterCleanup = Get-Content -LiteralPath (Join-Path $stateRoot "jobs\$unrelatedStaleId.json") -Raw | ConvertFrom-Json
    Assert-True ($unrelatedAfterCleanup.status -eq 'running') 'Cleanup must not reconcile a stale record owned by another session.'
    Unregister-ManagedJobOwnerReference -Job $unrelatedAfterCleanup
    Remove-Item -LiteralPath (Join-Path $stateRoot "jobs\$unrelatedStaleId.json") -Force

    $unclaimedId = '20000101-000000-lifecycle-owned-starting-000001'
    $unclaimedRecord = [ordered]@{
        schemaVersion = 3; id = $unclaimedId; name = 'lifecycle-owned-starting'; kind = 'test'; status = 'starting'
        lifetime = 'turn'; ownerAgent = 'codex'; ownerSessionId = $testSessionId; visible = $false; keepTerminalOpen = $false
        processContainment = 'pending'; createdAtUtc = [datetime]::UtcNow.ToString('o'); startedAtUtc = $null; finishedAtUtc = $null
        hostPid = $null; hostStartedAtUtc = $null; executable = 'fixture'; argumentCount = 0; environmentNames = @()
        invocationFingerprint = ('3' * 64); workingDirectory = $testRoot; logPath = (Join-Path $stateRoot "logs\$unclaimedId.log")
        exitCode = $null; error = $null
    }
    $unclaimedRecord | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot "jobs\$unclaimedId.json") -Encoding utf8
    Register-ManagedJobOwnerReference -Job ([pscustomobject]$unclaimedRecord)
    $blockedSummary = (& $controller cleanup -StateRoot $stateRoot -OwnerAgent codex -OwnerSessionId $testSessionId -CleanupLifetime Turn | Out-String) | ConvertFrom-Json
    Assert-True ($blockedSummary.failures.id -contains $unclaimedId) 'Cleanup should report a matching process that cannot be verified.'
    Assert-True ($blockedSummary.failures.error -match 'verifiable host process') 'Cleanup failure should explain the missing process identity.'
    Remove-Item -LiteralPath (Join-Path $stateRoot "jobs\$unclaimedId.json") -Force

    # Killing the host alone closes its Windows Job Object and terminates the child.
    $contained = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-contained-crash' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Write-Output \"child-pid=$PID\"; Start-Sleep -Seconds 30') -Lifetime Persistent | Out-String) | ConvertFrom-Json
    $activeIds.Add($contained.id)
    $contained = Wait-JobStatus -Id $contained.id -Expected @('running')
    $childPid = Wait-LoggedProcessId -LogPath $contained.logPath -Pattern 'child-pid=(\d+)'
    Stop-Process -Id $contained.hostPid -Force
    $activeIds.Remove($contained.id) | Out-Null
    Assert-True (Wait-ProcessExit -TargetProcessId $childPid) 'Windows containment should terminate descendants when the managed host crashes.'
    Assert-True ((Get-JobStatus -Id $contained.id).status -eq 'orphaned') 'A crashed contained host should reconcile to an orphaned record without a live child.'

    # A missing PID plus recorded start identity reconciles to orphaned without killing anything.
    $orphanId = '20000101-000000-lifecycle-orphan-000001'
    $orphanRecord = [ordered]@{
        schemaVersion = 2; id = $orphanId; name = 'lifecycle-orphan'; kind = 'test'; status = 'running'; visible = $false
        sharedTerminal = $true
        keepTerminalOpen = $false; createdAtUtc = '2000-01-01T00:00:00Z'; startedAtUtc = '2000-01-01T00:00:01Z'
        finishedAtUtc = $null; hostPid = 2147483647; hostStartedAtUtc = '2000-01-01T00:00:01Z'; executable = 'fixture'
        argumentCount = 0; environmentNames = @(); invocationFingerprint = ('0' * 64); workingDirectory = $testRoot
        logPath = (Join-Path $stateRoot "logs\$orphanId.log"); exitCode = $null; error = $null
    }
    $orphanRecord | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot "jobs\$orphanId.json") -Encoding utf8
    @{ schemaVersion = 1; jobId = $orphanId; hostPid = 2147483647; wtSession = [guid]::NewGuid(); wtComClsid = [guid]::NewGuid() } |
        ConvertTo-Json | Set-Content -LiteralPath (Get-ManagedJobControlFile -Id $orphanId) -Encoding utf8
    $staleId = '20000101-000000-lifecycle-stale-start-000001'
    $staleLaunch = Join-Path $stateRoot "launch\$staleId.json"
    $staleRecord = [ordered]@{
        schemaVersion = 2; id = $staleId; name = 'lifecycle-stale-start'; kind = 'test'; status = 'starting'; visible = $false
        keepTerminalOpen = $false; createdAtUtc = [datetime]::UtcNow.AddMinutes(-1).ToString('o'); startedAtUtc = $null; finishedAtUtc = $null
        hostPid = $null; hostStartedAtUtc = $null; executable = 'fixture'; argumentCount = 0; environmentNames = @()
        invocationFingerprint = ('1' * 64); workingDirectory = $testRoot; logPath = (Join-Path $stateRoot "logs\$staleId.log")
        exitCode = $null; error = $null
    }
    $staleRecord | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot "jobs\$staleId.json") -Encoding utf8
    @{ executable = 'fixture'; arguments = @(); environment = @{} } | ConvertTo-Json | Set-Content -LiteralPath $staleLaunch -Encoding utf8
    $orphanSummary = (& $controller reconcile -StateRoot $stateRoot -Status orphaned | Out-String) | ConvertFrom-Json
    $orphan = @($orphanSummary.jobs | Where-Object id -eq $orphanId)[0]
    Assert-True ($orphan.status -eq 'orphaned') 'Reconcile should mark a missing recorded host orphaned.'
    Assert-True ($orphan.terminalControlState -eq 'released') `
        'Reconcile should add released control state to legacy shared-terminal records.'
    Assert-True (-not $orphan.processIdentity.matches) 'Orphan inspection should preserve and report identity mismatch.'
    Assert-True (-not (Test-Path -LiteralPath (Get-ManagedJobControlFile -Id $orphanId))) `
        'Orphan reconciliation should remove stale shared-terminal control metadata.'
    Assert-True (@($orphanSummary.jobs).id -contains $staleId) 'Reconcile should orphan a stale unclaimed start after its grace period.'
    Assert-True (-not (Test-Path -LiteralPath $staleLaunch)) 'Orphan reconciliation should remove an unclaimed launch handoff.'

    # WhatIf previews exact terminal candidates before synchronous pruning.
    $preview = (& $controller prune -StateRoot $stateRoot -OlderThanDays 0 -WhatIf | Out-String) | ConvertFrom-Json
    Assert-True ($preview.preview -and $preview.candidateCount -ge 4 -and $preview.removedCount -eq 0) 'Prune WhatIf should return candidates without deletion.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot "jobs\$orphanId.json")) 'Preview must preserve candidate records.'

    $pruned = (& $controller prune -StateRoot $stateRoot -OlderThanDays 0 | Out-String) | ConvertFrom-Json
    Assert-True ($pruned.removedCount -eq $preview.candidateCount) 'Prune should remove the previewed eligible records.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot "jobs\$orphanId.json"))) `
        'Prune should remove an eligible orphaned record.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'jobs') -File).Count -eq 0) 'All isolated terminal fixtures should be pruned.'

    [pscustomobject]@{ result = 'passed'; assertions = $assertionCount; isolatedStateRoot = $stateRoot } | ConvertTo-Json
} finally {
    foreach ($id in @($activeIds)) {
        try { & $controller stop -StateRoot $stateRoot -Id $id | Out-Null } catch {}
    }
    if ($testRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $testRoot) -like 'managed-jobs-lifecycle-*') {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $previousThreadId) {
        Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_THREAD_ID = $previousThreadId
    }
    if ($null -eq $previousStateRoot) {
        Remove-Item Env:MANAGED_JOBS_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:MANAGED_JOBS_ROOT = $previousStateRoot
    }
    if ($null -eq $previousCodexHome) {
        Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    } else {
        $env:CODEX_HOME = $previousCodexHome
    }
    if ($null -eq $previousClaudeHome) {
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    } else {
        $env:CLAUDE_CONFIG_DIR = $previousClaudeHome
    }
    if ($null -eq $previousClaudeSessionId) {
        Remove-Item Env:CLAUDE_CODE_SESSION_ID -ErrorAction SilentlyContinue
    } else {
        $env:CLAUDE_CODE_SESSION_ID = $previousClaudeSessionId
    }
}
