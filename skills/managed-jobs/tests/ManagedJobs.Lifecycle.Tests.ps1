[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$controller = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Invoke-ManagedJob.ps1'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ManagedJob.Common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('managed-jobs-lifecycle-' + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $testRoot 'state'
$activeIds = [Collections.Generic.List[string]]::new()
$assertionCount = 0

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

try {
    $null = New-Item -ItemType Directory -Path $stateRoot -Force
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source

    # A copied Claude-only skill remains self-contained because scripts resolve companions locally.
    $claudeSkill = Join-Path $testRoot '.claude\skills\managed-jobs'
    Copy-Item -LiteralPath (Split-Path -Parent $PSScriptRoot) -Destination $claudeSkill -Recurse
    $claudeController = Join-Path $claudeSkill 'scripts\Invoke-ManagedJob.ps1'
    $claudeSummary = (& $claudeController reconcile -StateRoot (Join-Path $testRoot 'claude-state') | Out-String) | ConvertFrom-Json
    Assert-True ($claudeSummary.total -eq 0) 'Claude-only copied controller should reconcile without Codex files.'

    # Start, record redaction, structured list/status, logs, and reconcile.
    $completed = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-complete' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Write-Output lifecycle-ok') -Environment @{ LIFECYCLE_MARKER = 'not-recorded'; GIT_AUTHOR_NAME = 'Lifecycle Test' } | Out-String) | ConvertFrom-Json
    $completed = Wait-JobStatus -Id $completed.id -Expected @('completed')
    $recordText = Get-Content -LiteralPath (Join-Path $stateRoot "jobs\$($completed.id).json") -Raw
    Assert-True ($recordText -notmatch 'lifecycle-ok|not-recorded|Lifecycle Test') 'Permanent records must omit argument text and environment values.'
    Assert-True ($completed.schemaVersion -eq 2) 'New records should use schema version 2.'
    $logText = (& $controller logs -Id $completed.id -StateRoot $stateRoot -Tail 20 | Out-String)
    Assert-True ($logText -match 'lifecycle-ok') 'Logs should capture child output.'
    Assert-True ($logText -notmatch 'Write-Output lifecycle-ok|LIFECYCLE_MARKER|not-recorded') 'Controller log metadata must omit arguments and environment.'
    $completedList = @((& $controller list -StateRoot $stateRoot -Status completed -Json | Out-String) | ConvertFrom-Json)
    Assert-True ($completedList.id -contains $completed.id) 'Structured list filter should return the completed job.'
    $completedStatus = @((& $controller status -StateRoot $stateRoot -Status completed -Json | Out-String) | ConvertFrom-Json)
    Assert-True ($completedStatus.id -contains $completed.id) 'Structured status filter should return the completed job.'

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
        -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') | Out-String) | ConvertFrom-Json
    $activeIds.Add($running.id)
    $running = Wait-JobStatus -Id $running.id -Expected @('running')
    $duplicateRejected = $false
    try {
        & $controller start -StateRoot $stateRoot -Name 'lifecycle-duplicate' -Executable $pwsh `
            -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') | Out-Null
    } catch { $duplicateRejected = $_.Exception.Message -match [regex]::Escape($running.id) }
    Assert-True $duplicateRejected 'Equivalent active launch should be rejected with the existing id.'
    $stopped = (& $controller stop -StateRoot $stateRoot -Id $running.id | Out-String) | ConvertFrom-Json
    $activeIds.Remove($running.id) | Out-Null
    Assert-True ($stopped.status -eq 'stopped') 'Stop should record a stopped terminal state.'
    Assert-True ($stopped.PSObject.Properties.Name -notcontains 'processIdentity') 'Terminal jobs should not inspect potentially reused PIDs.'

    # A missing PID plus recorded start identity reconciles to orphaned without killing anything.
    $orphanId = '20000101-000000-lifecycle-orphan-000001'
    $orphanRecord = [ordered]@{
        schemaVersion = 2; id = $orphanId; name = 'lifecycle-orphan'; kind = 'test'; status = 'running'; visible = $false
        keepTerminalOpen = $false; createdAtUtc = '2000-01-01T00:00:00Z'; startedAtUtc = '2000-01-01T00:00:01Z'
        finishedAtUtc = $null; hostPid = 2147483647; hostStartedAtUtc = '2000-01-01T00:00:01Z'; executable = 'fixture'
        argumentCount = 0; environmentNames = @(); invocationFingerprint = ('0' * 64); workingDirectory = $testRoot
        logPath = (Join-Path $stateRoot "logs\$orphanId.log"); exitCode = $null; error = $null
    }
    $orphanRecord | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot "jobs\$orphanId.json") -Encoding utf8
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
    Assert-True (-not $orphan.processIdentity.matches) 'Orphan inspection should preserve and report identity mismatch.'
    Assert-True (@($orphanSummary.jobs).id -contains $staleId) 'Reconcile should orphan a stale unclaimed start after its grace period.'
    Assert-True (-not (Test-Path -LiteralPath $staleLaunch)) 'Orphan reconciliation should remove an unclaimed launch handoff.'

    # WhatIf previews exact terminal candidates, then real prune removes them and managed logs only.
    $preview = (& $controller prune -StateRoot $stateRoot -OlderThanDays 0 -WhatIf | Out-String) | ConvertFrom-Json
    Assert-True ($preview.preview -and $preview.candidateCount -ge 3 -and $preview.removedCount -eq 0) 'Prune WhatIf should return candidates without deletion.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot "jobs\$orphanId.json")) 'Preview must preserve candidate records.'
    $pruned = (& $controller prune -StateRoot $stateRoot -OlderThanDays 0 | Out-String) | ConvertFrom-Json
    Assert-True ($pruned.removed -contains $orphanId) 'Prune should remove the orphan candidate after preview.'
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
}
