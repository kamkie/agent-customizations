[CmdletBinding()]
param(
    [switch]$RequireUserInput
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$controller = Join-Path $skillRoot 'scripts\Invoke-ManagedJob.ps1'
. (Join-Path $skillRoot 'scripts\ManagedJob.Common.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('managed-jobs-shared-terminal-' + [guid]::NewGuid().ToString('N'))
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
    throw "Timed out waiting for $Id to reach a terminal status."
}

function Wait-PanePattern {
    param([string]$Id, [string]$Pattern, [int]$Seconds = 10)
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    do {
        try {
            $captured = (& $controller capture -Id $Id -StateRoot $stateRoot -MaxLines 120 | Out-String)
            if ($captured -match $Pattern) { return $captured }
        } catch {
            if ([datetime]::UtcNow -ge $deadline) { throw }
        }
        Start-Sleep -Milliseconds 150
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Timed out waiting for expected shared-terminal output for $Id."
}

function Wait-LoggedProcessId {
    param([string]$LogPath, [string]$Pattern, [int]$Seconds = 10)
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    do {
        $log = if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath -Raw } else { '' }
        if ($log -match $Pattern) { return [int]$Matches[1] }
        Start-Sleep -Milliseconds 100
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'Timed out waiting for the managed child process id.'
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

try {
    $null = New-Item -ItemType Directory -Path $stateRoot -Force
    Set-ManagedJobStateRoot -Path $stateRoot
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $skillRoot '..\..')).Path
    $env:CODEX_HOME = $repoRoot
    $env:CODEX_THREAD_ID = 'shared-terminal-lifecycle-session'
    $env:MANAGED_JOBS_ROOT = $stateRoot

    $tools = Resolve-IntelligentTerminalTools
    Assert-True (
        (Split-Path -Leaf $tools.wtai) -eq 'wtai.exe' -and
        (Split-Path -Leaf $tools.wtcli) -eq 'wtcli.exe' -and
        [version]$tools.packageVersion -ge [version]'0.2.2192.0'
    ) 'Shared-terminal tools should resolve from the installed Microsoft package.'

    $interactiveCommand = @'
Write-Output "shared-child-pid=$PID"
Write-Output 'shared-ready'
while ($true) {
    $value = Read-Host 'shared-input'
    if ($value -eq 'agent-literal-marker') {
        Write-Output 'agent-marker-observed'
    } elseif ($value -eq 'secure-test') {
        $maskedValue = Read-Host 'masking-probe' -AsSecureString
        $maskedValue.Dispose()
        Write-Output 'secure-fake-received'
    } elseif ($value -eq 'user-literal-marker') {
        Write-Output 'user-marker-observed'
    }
}
'@
    $shared = (& $controller start -StateRoot $stateRoot -Name 'shared-terminal-interactive' `
        -Executable $pwsh -Arguments @('-NoProfile', '-Command', $interactiveCommand) `
        -Visible -SharedTerminal | Out-String) | ConvertFrom-Json
    $activeIds.Add($shared.id)
    $shared = Wait-JobStatus -Id $shared.id -Expected @('running')
    Assert-True ($shared.schemaVersion -eq 4 -and $shared.visible -and $shared.sharedTerminal) `
        'Shared-terminal launch should use the durable opt-in schema.'
    Assert-True ($shared.processContainment -eq 'windows-job-object-kill-on-close') `
        'The in-pane host should retain Windows Job Object containment.'

    $controlFile = Get-ManagedJobControlFile -Id $shared.id
    Assert-True (Test-Path -LiteralPath $controlFile -PathType Leaf) `
        'The in-pane host should register job-scoped terminal control metadata.'
    $control = Get-Content -LiteralPath $controlFile -Raw | ConvertFrom-Json
    $recordText = Get-Content -LiteralPath (Get-ManagedJobFile -Id $shared.id) -Raw
    $logText = Get-Content -LiteralPath $shared.logPath -Raw
    foreach ($privateValue in @([string]$control.wtSession, [string]$control.wtComClsid)) {
        Assert-True ($recordText -notmatch [regex]::Escape($privateValue)) `
            'Durable job records must not expose terminal control identifiers.'
        Assert-True ($logText -notmatch [regex]::Escape($privateValue)) `
            'Ordinary logs must not expose terminal control identifiers.'
    }

    $missingControlBackup = "$controlFile.missing-control-test"
    Move-Item -LiteralPath $controlFile -Destination $missingControlBackup
    try {
        $missingControlError = $null
        try {
            & $controller capture -Id $shared.id -StateRoot $stateRoot -MaxLines 1 | Out-Null
        } catch { $missingControlError = $_.Exception.Message }
        Assert-True (
            $missingControlError -match 'invalid shared-terminal control metadata' -and
            $missingControlError -notmatch [regex]::Escape($controlFile)
        ) 'Missing control metadata should fail without exposing its private path.'
    } finally {
        Move-Item -LiteralPath $missingControlBackup -Destination $controlFile
    }

    $targetRejected = $false
    try {
        & $controller capture -Id $shared.id -StateRoot $stateRoot -Target ([guid]::NewGuid()) | Out-Null
    } catch { $targetRejected = $_.Exception.Message -match 'Target' }
    Assert-True $targetRejected 'Shared-terminal actions must not accept an arbitrary pane target.'

    $null = & $controller send-input -Id $shared.id -StateRoot $stateRoot -InputText 'agent-literal-marker'
    $null = & $controller send-key -Id $shared.id -StateRoot $stateRoot -Key Enter
    $captured = Wait-PanePattern -Id $shared.id -Pattern 'agent-marker-observed'
    Assert-True ($captured -match 'agent-marker-observed') `
        'Literal input plus the named Enter key should reach only the registered pane.'

    $null = & $controller send-input -Id $shared.id -StateRoot $stateRoot -InputText 'secure-test'
    $null = & $controller send-key -Id $shared.id -StateRoot $stateRoot -Key Enter
    Start-Sleep -Milliseconds 400
    $fakeSecretText = 'fake-masking-probe'
    $null = & $controller send-input -Id $shared.id -StateRoot $stateRoot -InputText $fakeSecretText
    $null = & $controller send-key -Id $shared.id -StateRoot $stateRoot -Key Enter
    $secureCapture = Wait-PanePattern -Id $shared.id -Pattern 'secure-fake-received'
    Assert-True ($secureCapture -notmatch [regex]::Escape($fakeSecretText)) `
        'Secure prompt capture must not expose the fake masking probe.'
    Assert-True ($secureCapture -match '\*{3,}') 'Secure prompt capture should contain masking characters.'

    if ($RequireUserInput) {
        Write-Output "Type user-literal-marker and Enter in the shared-terminal-interactive window."
        $userCapture = Wait-PanePattern -Id $shared.id -Pattern 'user-marker-observed' -Seconds 60
        Assert-True ($userCapture -match 'user-marker-observed') `
            'Direct user input should reach the visible managed pane.'
    }

    $sharedChildPid = Wait-LoggedProcessId -LogPath $shared.logPath -Pattern 'shared-child-pid=(\d+)'
    $stopped = (& $controller stop -Id $shared.id -StateRoot $stateRoot | Out-String) | ConvertFrom-Json
    $activeIds.Remove($shared.id) | Out-Null
    Assert-True ($stopped.status -eq 'stopped' -and $stopped.terminalControlState -eq 'released') `
        'Explicit stop should stop a shared-terminal job and release its control metadata.'
    Assert-True (Wait-ProcessExit -TargetProcessId $sharedChildPid) `
        'Explicit stop should terminate the shared-terminal child through Job Object containment.'
    Assert-True (-not (Test-Path -LiteralPath $controlFile)) `
        'Explicit stop should remove shared-terminal control metadata.'

    $interruptCommand = @'
$previousControlCMode = [Console]::TreatControlCAsInput
try {
    [Console]::TreatControlCAsInput = $true
    Write-Output 'interrupt-ready'
    $pressedKey = [Console]::ReadKey($true)
    Write-Output "interrupt-key-code=$([int]$pressedKey.KeyChar)"
} finally {
    [Console]::TreatControlCAsInput = $previousControlCMode
}
'@
    $interrupt = (& $controller start -StateRoot $stateRoot -Name 'shared-terminal-interrupt' `
        -Executable $pwsh -Arguments @('-NoProfile', '-Command', $interruptCommand) `
        -Visible -SharedTerminal -Lifetime Persistent | Out-String) | ConvertFrom-Json
    $activeIds.Add($interrupt.id)
    $null = Wait-PanePattern -Id $interrupt.id -Pattern 'interrupt-ready'
    $null = & $controller send-key -Id $interrupt.id -StateRoot $stateRoot -Key 'Ctrl+C'
    $interrupt = Wait-JobStatus -Id $interrupt.id -Expected @('completed', 'failed') -Seconds 10
    $activeIds.Remove($interrupt.id) | Out-Null
    $interruptLog = Get-Content -LiteralPath $interrupt.logPath -Raw
    Assert-True (
        $interrupt.status -eq 'completed' -and
        $interruptLog -match 'interrupt-key-code=3' -and
        $interrupt.terminalControlState -eq 'released'
    ) 'The named Ctrl+C key should reach the foreground process without orphaning the managed host.'

    $orphan = (& $controller start -StateRoot $stateRoot -Name 'shared-terminal-orphan' `
        -Executable $pwsh -Arguments @('-NoProfile', '-Command', 'Write-Output "orphan-child-pid=$PID"; Start-Sleep -Seconds 30') `
        -Visible -SharedTerminal -Lifetime Persistent | Out-String) | ConvertFrom-Json
    $activeIds.Add($orphan.id)
    $orphan = Wait-JobStatus -Id $orphan.id -Expected @('running')
    $orphanControlFile = Get-ManagedJobControlFile -Id $orphan.id
    $orphanChildPid = Wait-LoggedProcessId -LogPath $orphan.logPath -Pattern 'orphan-child-pid=(\d+)'
    Stop-Process -Id $orphan.hostPid -Force
    $activeIds.Remove($orphan.id) | Out-Null
    Assert-True (Wait-ProcessExit -TargetProcessId $orphanChildPid) `
        'A crashed shared-terminal host should terminate its child through Job Object containment.'
    $orphan = Wait-JobStatus -Id $orphan.id -Expected @('orphaned')
    Assert-True ($orphan.status -eq 'orphaned' -and $orphan.terminalControlState -eq 'released') `
        'Reconcile should mark a crashed shared-terminal host orphaned and release its control metadata.'
    Assert-True (-not (Test-Path -LiteralPath $orphanControlFile)) `
        'Orphan reconciliation should remove shared-terminal control metadata.'

    $turnOwned = (& $controller start -StateRoot $stateRoot -Name 'shared-terminal-turn-cleanup' `
        -Executable $pwsh -Arguments @('-NoProfile', '-Command', 'Write-Output "turn-child-pid=$PID"; Start-Sleep -Seconds 30') `
        -Visible -SharedTerminal | Out-String) | ConvertFrom-Json
    $activeIds.Add($turnOwned.id)
    $turnOwned = Wait-JobStatus -Id $turnOwned.id -Expected @('running')
    $turnChildPid = Wait-LoggedProcessId -LogPath $turnOwned.logPath -Pattern 'turn-child-pid=(\d+)'
    $turnControlFile = Get-ManagedJobControlFile -Id $turnOwned.id
    $cleanup = (& $controller cleanup -StateRoot $stateRoot -OwnerAgent codex `
        -OwnerSessionId $env:CODEX_THREAD_ID -CleanupLifetime Turn | Out-String) | ConvertFrom-Json
    $activeIds.Remove($turnOwned.id) | Out-Null
    Assert-True ($cleanup.stopped.id -contains $turnOwned.id) `
        'Turn cleanup should stop its shared-terminal job.'
    Assert-True (Wait-ProcessExit -TargetProcessId $turnChildPid) `
        'Turn cleanup should terminate the shared-terminal child.'
    Assert-True (-not (Test-Path -LiteralPath $turnControlFile)) `
        'Turn cleanup should remove shared-terminal control metadata.'

    $sessionOwned = (& $controller start -StateRoot $stateRoot -Name 'shared-terminal-session-cleanup' `
        -Executable $pwsh -Arguments @('-NoProfile', '-Command', 'Write-Output "session-child-pid=$PID"; Start-Sleep -Seconds 30') `
        -Visible -SharedTerminal -Lifetime Session | Out-String) | ConvertFrom-Json
    $activeIds.Add($sessionOwned.id)
    $sessionOwned = Wait-JobStatus -Id $sessionOwned.id -Expected @('running')
    $sessionChildPid = Wait-LoggedProcessId -LogPath $sessionOwned.logPath -Pattern 'session-child-pid=(\d+)'
    $sessionControlFile = Get-ManagedJobControlFile -Id $sessionOwned.id
    $sessionCleanup = (& $controller cleanup -StateRoot $stateRoot -OwnerAgent codex `
        -OwnerSessionId $env:CODEX_THREAD_ID -CleanupLifetime Turn,Session | Out-String) | ConvertFrom-Json
    $activeIds.Remove($sessionOwned.id) | Out-Null
    Assert-True ($sessionCleanup.stopped.id -contains $sessionOwned.id) `
        'Session cleanup should stop its shared-terminal job.'
    Assert-True (Wait-ProcessExit -TargetProcessId $sessionChildPid) `
        'Session cleanup should terminate the shared-terminal child.'
    Assert-True (-not (Test-Path -LiteralPath $sessionControlFile)) `
        'Session cleanup should remove shared-terminal control metadata.'

    [pscustomobject]@{
        result = 'passed'
        assertions = $assertionCount
        userInputValidated = [bool]$RequireUserInput
        packageVersion = $tools.packageVersion
    } | ConvertTo-Json
} finally {
    foreach ($id in @($activeIds)) {
        try { & $controller stop -StateRoot $stateRoot -Id $id | Out-Null } catch {}
    }
    if ($testRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $testRoot) -like 'managed-jobs-shared-terminal-*') {
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
