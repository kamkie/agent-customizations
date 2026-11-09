[CmdletBinding()]
param()

# Contract test for the calls agents make most often: a bounded wait that
# expires, a stop on a job that already ended, a collection listing, and the
# active-record scan that start runs while it holds the launch lock. Fixture
# records stand in for jobs, so only one short real job is launched.

$ErrorActionPreference = 'Stop'
$scriptsRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
$controller = Join-Path $scriptsRoot 'Invoke-ManagedJob.ps1'
. (Join-Path $scriptsRoot 'ManagedJob.Common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('managed-jobs-contract-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $testRoot 'state'
$assertionCount = 0
$startedId = $null

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:assertionCount++
}

function New-FixtureRecord {
    param([string]$Id, [string]$Name, [string]$Status, [int]$AgeMinutes, [string]$Fingerprint = ('c' * 64))
    # A running fixture names this test process as its host, so reconciliation
    # keeps it active. Nothing in this test may stop a running fixture. Ended
    # fixtures name a process id that cannot exist.
    $active = $Status -in @('starting', 'running')
    $created = [datetime]::UtcNow.AddMinutes(-$AgeMinutes)
    $hostPid = switch ($Status) { 'starting' { $null } 'running' { $PID } default { 2147483647 } }
    $hostStarted = switch ($Status) {
        'starting' { $null }
        'running' { (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') }
        default { $created.AddSeconds(1).ToString('o') }
    }
    $record = [ordered]@{
        schemaVersion = 3; id = $Id; name = $Name; kind = 'test'; status = $Status
        lifetime = 'persistent'; ownerAgent = $null; ownerSessionId = $null; visible = $false; keepTerminalOpen = $false
        processContainment = 'windows-job-object-kill-on-close'; createdAtUtc = $created.ToString('o')
        startedAtUtc = $(if ($Status -eq 'starting') { $null } else { $created.AddSeconds(1).ToString('o') })
        finishedAtUtc = $(if ($active) { $null } else { $created.AddSeconds(2).ToString('o') })
        hostPid = $hostPid; hostStartedAtUtc = $hostStarted
        executable = 'fixture'; argumentCount = 0; environmentNames = @(); invocationFingerprint = $Fingerprint
        workingDirectory = $testRoot; logPath = (Join-Path $stateRoot "logs\$Id.log")
        exitCode = $(if ($active) { $null } else { 0 }); error = $null
    }
    Write-ManagedJob -Path (Get-ManagedJobFile -Id $Id) -Job $record
}

function Invoke-ControllerProcess {
    # A separate process shows the exit code a caller outside PowerShell sees.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = (& $pwsh -NoProfile -ExecutionPolicy Bypass -File $controller @Arguments -StateRoot $stateRoot 2>&1 | Out-String)
    return [pscustomobject]@{ exitCode = $LASTEXITCODE; output = $output }
}

function Get-RecordKey {
    param([string]$Id)
    $file = [IO.FileInfo]::new((Get-ManagedJobFile -Id $Id))
    return '{0}|{1}|{2}' -f $file.Name, $file.LastWriteTimeUtc.Ticks, $file.Length
}

try {
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    Set-ManagedJobStateRoot -Path $stateRoot
    $cachePath = Join-Path (Get-ManagedJobRoot) '.terminal-records.cache'

    $completedId = '20000101-000000-contract-completed-000001'
    $failedId = '20000101-000000-contract-failed-000001'
    $stoppedId = '20000101-000000-contract-stopped-000001'
    $orphanedId = '20000101-000000-contract-orphaned-000001'
    $runningId = '20000101-000000-contract-running-000001'
    $terminalIds = @($completedId, $failedId, $stoppedId, $orphanedId)
    New-FixtureRecord -Id $completedId -Name 'contract build' -Status completed -AgeMinutes 50
    New-FixtureRecord -Id $failedId -Name 'contract build' -Status failed -AgeMinutes 40
    New-FixtureRecord -Id $stoppedId -Name 'contract server' -Status stopped -AgeMinutes 30
    New-FixtureRecord -Id $orphanedId -Name 'contract watcher' -Status orphaned -AgeMinutes 20
    New-FixtureRecord -Id $runningId -Name 'contract server' -Status running -AgeMinutes 10
    $damagedPath = Join-Path $stateRoot 'jobs\20000101-000000-contract-damaged-000001.json'
    Set-Content -LiteralPath $damagedPath -Value '{' -Encoding utf8

    # The scan returns only active records and remembers terminal ones, so the
    # next scan can skip them without opening their files.
    $scan = @(Get-ManagedJobActiveRecords)
    Assert-True ($scan.Count -eq 1 -and $scan[0].id -eq $runningId) `
        'The active scan should return only the record that is starting or running.'
    Assert-True (-not (Test-Path -LiteralPath $cachePath)) `
        'A scan that was not asked to update the cache must not write it.'
    $scan = @(Get-ManagedJobActiveRecords -UpdateCache)
    $expectedKeys = @($terminalIds | ForEach-Object { Get-RecordKey -Id $_ } | Sort-Object)
    $cachedKeys = @(Get-Content -LiteralPath $cachePath | Sort-Object)
    Assert-True ($scan.Count -eq 1 -and ($cachedKeys -join "`n") -eq ($expectedKeys -join "`n")) `
        'The cache should list exactly the terminal records, keyed by their file metadata.'
    $cacheWrittenAt = [IO.File]::GetLastWriteTimeUtc($cachePath)
    $scan = @(Get-ManagedJobActiveRecords -UpdateCache)
    Assert-True ($scan.Count -eq 1 -and [IO.File]::GetLastWriteTimeUtc($cachePath) -eq $cacheWrittenAt) `
        'A scan that recognizes every cached record should find nothing new and leave the cache untouched.'

    # A cached entry describes one exact file. A rewritten record is read again.
    New-FixtureRecord -Id $stoppedId -Name 'contract server' -Status running -AgeMinutes 30
    $scan = @(Get-ManagedJobActiveRecords -UpdateCache)
    Assert-True ($scan.Count -eq 2 -and $scan.id -contains $stoppedId) `
        'A record rewritten after it was cached must be read again and reported as active.'
    Assert-True (@(Get-Content -LiteralPath $cachePath).Count -eq 3) `
        'The cache should drop the entry of a record that is active again.'
    New-FixtureRecord -Id $stoppedId -Name 'contract server' -Status stopped -AgeMinutes 30
    $null = @(Get-ManagedJobActiveRecords -UpdateCache)

    # A late host can publish running over a cached terminal record while a
    # scan is under way. The directory listing was read before the rewrite, so
    # the scan must check the file itself before it trusts a cache entry. The
    # running fixture sorts before the stopped one and is emitted first; the
    # rewrite happens while the scan is paused on it.
    $scan = @(Get-ManagedJobActiveRecords | ForEach-Object {
        if ($_.id -eq $runningId) { New-FixtureRecord -Id $stoppedId -Name 'contract server' -Status running -AgeMinutes 30 }
        $_
    })
    Assert-True ($scan.Count -eq 2 -and $scan.id -contains $stoppedId) `
        'A cached record rewritten as active during a scan must still be reported by that scan.'
    New-FixtureRecord -Id $stoppedId -Name 'contract server' -Status stopped -AgeMinutes 30
    Set-Content -LiteralPath $cachePath -Value @('not a cache entry', "$completedId.json|1|1") -Encoding utf8
    $scan = @(Get-ManagedJobActiveRecords -UpdateCache)
    $cachedKeys = @(Get-Content -LiteralPath $cachePath | Sort-Object)
    $expectedKeys = @($terminalIds | ForEach-Object { Get-RecordKey -Id $_ } | Sort-Object)
    Assert-True ($scan.Count -eq 1 -and ($cachedKeys -join "`n") -eq ($expectedKeys -join "`n")) `
        'A damaged or stale cache should cost one full scan and be rebuilt, never hide or invent a record.'

    # wait: expiry is a normal result, not an error.
    $waitTimer = [Diagnostics.Stopwatch]::StartNew()
    $expired = Invoke-ControllerProcess -Arguments @('wait', '-Id', $runningId, '-TimeoutSeconds', '1')
    $waitTimer.Stop()
    $expiredRecord = $expired.output | ConvertFrom-Json
    Assert-True ($expired.exitCode -eq 0 -and $expiredRecord.id -eq $runningId -and $expiredRecord.status -eq 'running' -and
        $expiredRecord.timedOut -eq $true) `
        "An expired wait should exit 0 and return the current record with timedOut set. Output: $($expired.output)"
    Assert-True ($waitTimer.Elapsed.TotalSeconds -ge 1) 'An expired wait should have waited for its bound.'
    $finished = Invoke-ControllerProcess -Arguments @('wait', '-Id', $completedId, '-TimeoutSeconds', '5')
    $finishedRecord = $finished.output | ConvertFrom-Json
    Assert-True ($finished.exitCode -eq 0 -and $finishedRecord.status -eq 'completed' -and $finishedRecord.timedOut -eq $false) `
        'A wait on a finished job should return its record with timedOut cleared.'
    $unknownWait = Invoke-ControllerProcess -Arguments @('wait', '-Id', '20000101-000000-contract-unknown-000001', '-TimeoutSeconds', '1')
    Assert-True ($unknownWait.exitCode -ne 0 -and $unknownWait.output -match 'record not found') `
        'A wait on an unknown id should still fail.'

    # stop: a job that already ended returns its record unchanged.
    foreach ($terminalId in $terminalIds) {
        $before = Get-Content -LiteralPath (Get-ManagedJobFile -Id $terminalId) -Raw
        $stopResult = Invoke-ControllerProcess -Arguments @('stop', '-Id', $terminalId)
        $stopRecord = $stopResult.output | ConvertFrom-Json
        Assert-True ($stopResult.exitCode -eq 0 -and $stopRecord.id -eq $terminalId -and
            $stopRecord.status -eq ($before | ConvertFrom-Json).status) `
            "Stopping a job that already ended should exit 0 and return its record. Output: $($stopResult.output)"
        Assert-True ((Get-Content -LiteralPath (Get-ManagedJobFile -Id $terminalId) -Raw) -eq $before) `
            'Stopping a job that already ended must not change its record.'
    }
    $unknownStop = Invoke-ControllerProcess -Arguments @('stop', '-Id', '20000101-000000-contract-unknown-000001')
    Assert-True ($unknownStop.exitCode -ne 0 -and $unknownStop.output -match 'record not found') `
        'A stop on an unknown id should still fail.'

    # list and status without -Id: JSON by default, narrowed by name and status.
    $listed = Invoke-ControllerProcess -Arguments @('list')
    $listedJobs = @($listed.output | ConvertFrom-Json)
    Assert-True ($listed.exitCode -eq 0 -and $listedJobs.Count -eq 6 -and $listedJobs[0].id -eq $runningId) `
        "A plain list should print every record as JSON, newest first. Output: $($listed.output)"
    $statusJobs = @((Invoke-ControllerProcess -Arguments @('status')).output | ConvertFrom-Json)
    Assert-True ($statusJobs.Count -eq 6) 'A status call without an id should print the same JSON collection.'
    $flaggedJobs = @((Invoke-ControllerProcess -Arguments @('list', '-Json')).output | ConvertFrom-Json)
    Assert-True ($flaggedJobs.Count -eq 6) 'Callers that already pass -Json should keep working.'
    $named = @((Invoke-ControllerProcess -Arguments @('list', '-Name', 'SERVER')).output | ConvertFrom-Json)
    Assert-True ($named.Count -eq 2 -and $named.id -contains $runningId -and $named.id -contains $stoppedId) `
        'A name filter without wildcards should match part of the job name, ignoring case.'
    $wildcard = @((Invoke-ControllerProcess -Arguments @('list', '-Name', 'contract b*')).output | ConvertFrom-Json)
    Assert-True ($wildcard.Count -eq 2 -and $wildcard.id -contains $completedId -and $wildcard.id -contains $failedId) `
        'A name filter with wildcards should be used as the pattern.'
    $lost = @((Invoke-ControllerProcess -Arguments @('list', '-Name', 'contract server', '-Status', 'running')).output | ConvertFrom-Json)
    Assert-True ($lost.Count -eq 1 -and $lost[0].id -eq $runningId) `
        'Name and status together should recover the id of a running job.'
    $nothing = Invoke-ControllerProcess -Arguments @('list', '-Name', 'no such job')
    Assert-True ($nothing.exitCode -eq 0 -and @($nothing.output | ConvertFrom-Json).Count -eq 0) `
        'A filter that matches nothing should print an empty JSON array.'
    $table = Invoke-ControllerProcess -Arguments @('list', '-Table', '-Status', 'running')
    # Some hosts colour the table header, so compare the text without styling.
    $tableText = $table.output -replace '\x1b\[[0-9;]*m', ''
    Assert-True ($table.exitCode -eq 0 -and $tableText -match '\bid\s+name\s+kind\s+status\b' -and
        $tableText -match [regex]::Escape($runningId) -and $tableText -notmatch '^\s*\[') `
        "The table view should stay available behind -Table. Exit code $($table.exitCode). Output: $tableText"
    $conflict = Invoke-ControllerProcess -Arguments @('list', '-Table', '-Json')
    Assert-True ($conflict.exitCode -ne 0 -and $conflict.output -match 'cannot be combined with -Json') `
        'Asking for both output forms should be rejected.'

    # start: the equivalent-job check still sees active records with a cached
    # history, and a real launch runs end to end through the shortened lock.
    $duplicateArguments = @('-NoProfile', '-Command', 'Start-Sleep -Seconds 29')
    $startingId = '20000101-000000-contract-starting-000001'
    New-FixtureRecord -Id $startingId -Name 'contract starting' -Status starting -AgeMinutes 0 -Fingerprint (
        Get-InvocationFingerprint -Executable $pwsh -Arguments $duplicateArguments -WorkingDirectory $testRoot -Environment @{})
    $duplicateError = $null
    try {
        & $controller start -StateRoot $stateRoot -Name 'contract duplicate' -Executable $pwsh -Arguments $duplicateArguments `
            -WorkingDirectory $testRoot -Lifetime Persistent | Out-Null
    } catch { $duplicateError = $_.Exception.Message }
    Assert-True ($duplicateError -match [regex]::Escape($startingId)) `
        "An equivalent active record should still block a launch. Error: $duplicateError"
    Remove-Item -LiteralPath (Get-ManagedJobFile -Id $startingId) -Force

    $started = (& $controller start -StateRoot $stateRoot -Name 'contract real' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Write-Output contract-ok') -WorkingDirectory $testRoot `
        -Lifetime Persistent | Out-String) | ConvertFrom-Json
    $startedId = $started.id
    $final = (& $controller wait -StateRoot $stateRoot -Id $startedId -TimeoutSeconds 60 | Out-String) | ConvertFrom-Json
    Assert-True ($final.status -eq 'completed' -and $final.exitCode -eq 0 -and $final.timedOut -eq $false) `
        "A real job should start and complete with terminal history present. Status: $($final.status)"
    $startedId = $null
    $cachedNames = @(Get-Content -LiteralPath $cachePath | ForEach-Object { ($_ -split '\|')[0] })
    Assert-True (@($terminalIds | Where-Object { "$_.json" -notin $cachedNames }).Count -eq 0) `
        'A start should leave the terminal history cached for the next launch.'
    Assert-True ((Get-ManagedJobActiveRecords).id -contains $runningId) `
        'The active fixture should still be reported after a real launch.'

    [pscustomobject]@{ result = 'passed'; assertions = $assertionCount } | ConvertTo-Json
} finally {
    if ($startedId) {
        try { & $controller stop -StateRoot $stateRoot -Id $startedId | Out-Null } catch {}
    }
    if ($testRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $testRoot) -like 'managed-jobs-contract-*') {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
