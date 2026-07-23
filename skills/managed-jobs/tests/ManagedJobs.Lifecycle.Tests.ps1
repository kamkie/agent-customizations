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

try {
    $null = New-Item -ItemType Directory -Path $stateRoot -Force
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $testSessionId = 'codex-lifecycle-session'
    $env:CODEX_HOME = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
    $env:CODEX_THREAD_ID = $testSessionId
    $env:MANAGED_JOBS_ROOT = $stateRoot
    $null = & $controller reconcile -StateRoot $stateRoot

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

    $hiddenKeepOpenRejected = $false
    try {
        & $controller start -StateRoot $stateRoot -Name 'invalid-hidden-keep-open' -Executable $pwsh -KeepTerminalOpen | Out-Null
    } catch { $hiddenKeepOpenRejected = $_.Exception.Message -match 'requires -Visible' }
    Assert-True $hiddenKeepOpenRejected 'KeepTerminalOpen should require visible execution.'

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

    # Start, record redaction, structured list/status, logs, and reconcile.
    $completed = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-complete' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Write-Output lifecycle-ok') -Environment @{ LIFECYCLE_MARKER = 'not-recorded'; GIT_AUTHOR_NAME = 'Lifecycle Test' } | Out-String) | ConvertFrom-Json
    $completed = Wait-JobStatus -Id $completed.id -Expected @('completed')
    $recordText = Get-Content -LiteralPath (Join-Path $stateRoot "jobs\$($completed.id).json") -Raw
    Assert-True ($recordText -notmatch 'lifecycle-ok|not-recorded|Lifecycle Test') 'Permanent records must omit argument text and environment values.'
    Assert-True ($completed.schemaVersion -eq 3) 'New records should use schema version 3.'
    Assert-True ($completed.ownerAgent -eq 'codex' -and $completed.ownerSessionId -eq $testSessionId) 'Codex records should capture their owning session.'
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

    # Turn cleanup stops only matching Codex-owned work.
    $turnOwned = (& $controller start -StateRoot $stateRoot -Name 'lifecycle-turn-owned' -Executable $pwsh `
        -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') | Out-String) | ConvertFrom-Json
    $activeIds.Add($turnOwned.id)
    $turnOwned = Wait-JobStatus -Id $turnOwned.id -Expected @('running')
    $turnSummary = (& $controller cleanup -StateRoot $stateRoot -OwnerAgent codex -OwnerSessionId $testSessionId -CleanupLifetime Turn | Out-String) | ConvertFrom-Json
    Assert-True ($turnSummary.stopped.id -contains $turnOwned.id) 'Turn cleanup should report the stopped owned process.'
    $activeIds.Remove($turnOwned.id) | Out-Null
    Assert-True ((Get-JobStatus -Id $turnOwned.id).status -eq 'stopped') 'The Codex Stop hook should stop a matching turn-owned process tree.'
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
    $childPid = $null
    $childDeadline = [datetime]::UtcNow.AddSeconds(10)
    do {
        $containedLog = if (Test-Path -LiteralPath $contained.logPath) { Get-Content -LiteralPath $contained.logPath -Raw } else { '' }
        if ($containedLog -match 'child-pid=(\d+)') { $childPid = [int]$Matches[1] }
        if (-not $childPid) { Start-Sleep -Milliseconds 100 }
    } while (-not $childPid -and [datetime]::UtcNow -lt $childDeadline)
    Assert-True ([bool]$childPid) 'Containment test should observe the child PID.'
    Stop-Process -Id $contained.hostPid -Force
    $childExitDeadline = [datetime]::UtcNow.AddSeconds(10)
    do {
        $childAlive = $null -ne (Get-ProcessSnapshot -ProcessId $childPid)
        if ($childAlive) { Start-Sleep -Milliseconds 100 }
    } while ($childAlive -and [datetime]::UtcNow -lt $childExitDeadline)
    $activeIds.Remove($contained.id) | Out-Null
    Assert-True (-not $childAlive) 'Windows containment should terminate descendants when the managed host crashes.'
    Assert-True ((Get-JobStatus -Id $contained.id).status -eq 'orphaned') 'A crashed contained host should reconcile to an orphaned record without a live child.'

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
    Assert-True ($preview.preview -and $preview.candidateCount -ge 4 -and $preview.removedCount -eq 0) 'Prune WhatIf should return candidates without deletion.'
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
}
