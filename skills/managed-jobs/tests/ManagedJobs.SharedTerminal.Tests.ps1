[CmdletBinding()]
param(
    [switch]$RequireUserInput,
    [switch]$AllowForegroundBootstrap
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

function Wait-PaneProcessId {
    param([string]$Id, [string]$Pattern, [int]$Seconds = 10)
    $captured = Wait-PanePattern -Id $Id -Pattern $Pattern -Seconds $Seconds
    if ($captured -notmatch $Pattern) { throw 'The shared-terminal process id was not captured.' }
    return [int]$Matches[1]
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

function Get-ForegroundWindowHandle {
    if (-not ('ManagedJobsSharedTerminalNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ManagedJobsSharedTerminalNative
{
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
}
'@
    }
    return [ManagedJobsSharedTerminalNative]::GetForegroundWindow().ToInt64()
}

function Get-ActiveTerminalSession {
    param([Parameter(Mandatory)]$Connection)
    $result = Invoke-IntelligentTerminalCliProcess `
        -Tools $Connection.tools `
        -ComClsid $Connection.comClsid `
        -Arguments @('--json', 'active-pane')
    if ($result.exitCode -ne 0) { throw 'Unable to inspect the active Intelligent Terminal pane.' }
    $payload = $result.standardOutput | ConvertFrom-Json
    return [string]$payload.session_id
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
    $backgroundProbeError = $null
    try {
        $backgroundConnection = Get-LiveIntelligentTerminalConnection -Tools $tools
    } catch {
        $backgroundConnection = $null
        $backgroundProbeError = $_.Exception.Message
    }
    Assert-True (
        (Split-Path -Leaf $tools.wtcli) -eq 'wtcli.exe' -and
        $tools.packageFamilyName -eq 'Microsoft.IntelligentTerminal_8wekyb3d8bbwe' -and
        [version]$tools.packageVersion -ge [version]'0.2.2192.0'
    ) 'Shared-terminal tools should resolve from the installed Microsoft package.'
    $recordedTools = Resolve-RecordedIntelligentTerminalTools -Job ([pscustomobject]@{
        terminalPackageVersion = $tools.packageVersion
        terminalPackageRoot = $tools.packageRoot
        terminalCliPath = $tools.wtcli
    })
    Assert-True ($recordedTools.wtcli -eq $tools.wtcli) `
        'Recorded shared-terminal tool paths should revalidate without package discovery.'

    # Probe classification: only an explicit successful zero-window response may
    # report the terminal as absent; probe faults must throw, not bootstrap.
    $realPackageProcesses = ${function:Get-IntelligentTerminalPackageProcesses}
    $realCliProcess = ${function:Invoke-IntelligentTerminalCliProcess}
    try {
        $probeTools = [pscustomobject]@{
            packageRoot = $tools.packageRoot
            comClsid = $tools.comClsid
            wtcli = $tools.wtcli
        }
        function Get-IntelligentTerminalPackageProcesses { param($Tools) @([pscustomobject]@{ Id = 424242 }) }

        function Invoke-IntelligentTerminalCliProcess { param($Tools, $ComClsid, $SessionId, $Arguments, $TimeoutSeconds)
            [pscustomobject]@{ exitCode = 0; standardOutput = '{"windows":[{"window_id":1}]}'; standardError = '' }
        }
        Assert-True ($null -ne (Get-LiveIntelligentTerminalConnection -Tools $probeTools)) `
            'A successful probe with a window should produce a connection.'

        function Invoke-IntelligentTerminalCliProcess { param($Tools, $ComClsid, $SessionId, $Arguments, $TimeoutSeconds)
            [pscustomobject]@{ exitCode = 0; standardOutput = '{"windows":[]}'; standardError = '' }
        }
        Assert-True ($null -eq (Get-LiveIntelligentTerminalConnection -Tools $probeTools)) `
            'A verified zero-window response should report the terminal as absent.'

        function Invoke-IntelligentTerminalCliProcess { param($Tools, $ComClsid, $SessionId, $Arguments, $TimeoutSeconds)
            [pscustomobject]@{ exitCode = 1; standardOutput = ''; standardError = 'probe-broke' }
        }
        $probeFailure = $null
        try { Get-LiveIntelligentTerminalConnection -Tools $probeTools | Out-Null } catch { $probeFailure = $_.Exception.Message }
        Assert-True ($probeFailure -match 'probe kept failing') `
            'A persistent nonzero probe exit should throw instead of reporting absence.'

        function Invoke-IntelligentTerminalCliProcess { param($Tools, $ComClsid, $SessionId, $Arguments, $TimeoutSeconds)
            [pscustomobject]@{ exitCode = 0; standardOutput = 'not-json{'; standardError = '' }
        }
        $probeFailure = $null
        try { Get-LiveIntelligentTerminalConnection -Tools $probeTools | Out-Null } catch { $probeFailure = $_.Exception.Message }
        Assert-True ($probeFailure -match 'probe kept failing') `
            'Malformed probe output should throw instead of reporting absence.'

        function Invoke-IntelligentTerminalCliProcess { param($Tools, $ComClsid, $SessionId, $Arguments, $TimeoutSeconds)
            throw 'The Intelligent Terminal CLI timed out.'
        }
        $probeFailure = $null
        try { Get-LiveIntelligentTerminalConnection -Tools $probeTools | Out-Null } catch { $probeFailure = $_.Exception.Message }
        Assert-True ($probeFailure -match 'probe kept failing') `
            'A persistent probe timeout should throw instead of reporting absence.'

        function Invoke-IntelligentTerminalCliProcess { param($Tools, $ComClsid, $SessionId, $Arguments, $TimeoutSeconds)
            [pscustomobject]@{ exitCode = 0; standardOutput = '{"windows":null}'; standardError = '' }
        }
        $probeFailure = $null
        try { Get-LiveIntelligentTerminalConnection -Tools $probeTools | Out-Null } catch { $probeFailure = $_.Exception.Message }
        Assert-True ($probeFailure -match 'probe kept failing') `
            'A null windows value should throw instead of counting as a live window.'

        function Invoke-IntelligentTerminalCliProcess { param($Tools, $ComClsid, $SessionId, $Arguments, $TimeoutSeconds)
            [pscustomobject]@{ exitCode = 0; standardOutput = '{"windows":{}}'; standardError = '' }
        }
        $probeFailure = $null
        try { Get-LiveIntelligentTerminalConnection -Tools $probeTools | Out-Null } catch { $probeFailure = $_.Exception.Message }
        Assert-True ($probeFailure -match 'probe kept failing') `
            'An object-valued windows property should throw instead of counting as a live window.'

        function Get-IntelligentTerminalPackageProcesses { param($Tools) @() }
        function Invoke-IntelligentTerminalCliProcess { param($Tools, $ComClsid, $SessionId, $Arguments, $TimeoutSeconds)
            throw 'the probe must not run without package processes'
        }
        Assert-True ($null -eq (Get-LiveIntelligentTerminalConnection -Tools $probeTools)) `
            'No package process should report absence without probing the protocol.'

        $profileConnection = [pscustomobject]@{ tools = $probeTools; comClsid = $probeTools.comClsid }
        function Invoke-IntelligentTerminalCliProcess { param($Tools, $ComClsid, $SessionId, $Arguments, $TimeoutSeconds)
            [pscustomobject]@{
                exitCode = 0
                standardOutput = '{"profiles":{"list":[{"name":"Git Bash","guid":"{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}"},{"guid":"{99999999-8888-7777-6666-555555555555}"},{"name":"Renamed Shell","source":"Windows.Terminal.PowershellCore","guid":"{11111111-2222-3333-4444-555555555555}","hidden":false}]}}'
                standardError = ''
            }
        }
        $renamedProfile = Resolve-PowerShellTerminalProfile -Connection $profileConnection
        Assert-True (
            $renamedProfile.name -eq 'Renamed Shell' -and
            $renamedProfile.id -eq '{11111111-2222-3333-4444-555555555555}'
        ) 'PowerShell profile discovery should survive a renamed display label.'

        function Invoke-IntelligentTerminalCliProcess { param($Tools, $ComClsid, $SessionId, $Arguments, $TimeoutSeconds)
            [pscustomobject]@{ exitCode = 0; standardOutput = '{"profiles":{"list":[]}}'; standardError = '' }
        }
        Assert-True ($null -eq (Resolve-PowerShellTerminalProfile -Connection $profileConnection)) `
            'Missing PowerShell profile metadata should fall back without failing the launch.'
    } finally {
        Set-Item -Path function:Get-IntelligentTerminalPackageProcesses -Value $realPackageProcesses
        Set-Item -Path function:Invoke-IntelligentTerminalCliProcess -Value $realCliProcess
    }
    if (-not $backgroundConnection -and -not $AllowForegroundBootstrap) {
        $backgroundRequirementRejected = $false
        try {
            & $controller start -StateRoot $stateRoot -Name 'background-required-without-window' `
                -Executable $pwsh -Visible -SharedTerminal -RequireBackgroundTab | Out-Null
        } catch {
            $backgroundRequirementRejected = $_.Exception.Message -match (
                'already-running Microsoft Intelligent Terminal window'
            )
        }
        Assert-True $backgroundRequirementRejected `
            'RequireBackgroundTab should reject a focus-stealing cold bootstrap.'
        [pscustomobject]@{
            result = 'skipped'
            reason = if ($backgroundProbeError) {
                'A running Microsoft Intelligent Terminal process was not protocol-ready; refusing a focus-stealing fallback.'
            } else {
                'No running Microsoft Intelligent Terminal window; refusing a focus-stealing cold bootstrap.'
            }
            assertions = $assertionCount
            packageVersion = $tools.packageVersion
        } | ConvertTo-Json
        return
    }
    $backgroundOnlyParameters = if ($AllowForegroundBootstrap) { @{} } else { @{ RequireBackgroundTab = $true } }
    $foregroundBefore = if ($backgroundConnection) { Get-ForegroundWindowHandle } else { $null }
    $activeSessionBefore = if ($backgroundConnection) {
        Get-ActiveTerminalSession -Connection $backgroundConnection
    } else {
        $null
    }

    $interactiveCommand = @'
Write-Output "shared-child-pid=$PID"
Write-Output "shared-profile-id=$env:WT_PROFILE_ID"
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
        -Visible -SharedTerminal @backgroundOnlyParameters | Out-String) | ConvertFrom-Json
    $activeIds.Add($shared.id)
    $shared = Wait-JobStatus -Id $shared.id -Expected @('running')
    Assert-True ($shared.schemaVersion -eq 4 -and $shared.visible -and $shared.sharedTerminal) `
        'Shared-terminal launch should use the durable opt-in schema.'
    Assert-True ($shared.processContainment -eq 'windows-job-object-kill-on-close') `
        'The in-pane host should retain Windows Job Object containment.'
    if ($backgroundConnection) {
        Assert-True ($shared.terminalLaunchMode -eq 'background-tab') `
            'A live Intelligent Terminal should use background-tab launch mode.'
        Assert-True ((Get-ForegroundWindowHandle) -eq $foregroundBefore) `
            'Background-tab launch must not change the foreground window.'
        Assert-True (
            (Get-ActiveTerminalSession -Connection $backgroundConnection) -eq $activeSessionBefore
        ) 'Background-tab launch must leave the user active pane unchanged.'
    }

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
    $liveProfileConnection = Get-LiveIntelligentTerminalConnection -Tools $tools
    $expectedPowerShellProfile = if ($liveProfileConnection) {
        Resolve-PowerShellTerminalProfile -Connection $liveProfileConnection
    } else {
        $null
    }
    if ($expectedPowerShellProfile) {
        Assert-True ($captured -match (
                'shared-profile-id=' + [regex]::Escape($expectedPowerShellProfile.id)
            )) 'The shared tab should use the discovered PowerShell profile.'
    }
    Assert-True ($captured -match 'shared-input:\s*agent-literal-marker') `
        'The interactive prompt should render before the submitted input.'

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

    $sharedChildPid = Wait-PaneProcessId -Id $shared.id -Pattern 'shared-child-pid=(\d+)'
    $stopped = (& $controller stop -Id $shared.id -StateRoot $stateRoot | Out-String) | ConvertFrom-Json
    $activeIds.Remove($shared.id) | Out-Null
    Assert-True ($stopped.status -eq 'stopped' -and $stopped.terminalControlState -eq 'released') `
        'Explicit stop should stop a shared-terminal job and release its control metadata.'
    Assert-True (Wait-ProcessExit -TargetProcessId $sharedChildPid) `
        'Explicit stop should terminate the shared-terminal child through Job Object containment.'
    Assert-True (-not (Test-Path -LiteralPath $controlFile)) `
        'Explicit stop should remove shared-terminal control metadata.'

    $interruptCommand = 'Write-Output ''interrupt-ready''; while ($true) { Start-Sleep -Seconds 1 }'
    $interrupt = (& $controller start -StateRoot $stateRoot -Name 'shared-terminal-interrupt' `
        -Executable $pwsh -Arguments @('-NoProfile', '-Command', $interruptCommand) `
        -Visible -SharedTerminal -Lifetime Persistent @backgroundOnlyParameters | Out-String) | ConvertFrom-Json
    $activeIds.Add($interrupt.id)
    $null = Wait-PanePattern -Id $interrupt.id -Pattern 'interrupt-ready'
    $null = & $controller send-key -Id $interrupt.id -StateRoot $stateRoot -Key 'Ctrl+C'
    $interrupt = Wait-JobStatus -Id $interrupt.id -Expected @('completed', 'failed') -Seconds 10
    $activeIds.Remove($interrupt.id) | Out-Null
    $interruptLog = Get-Content -LiteralPath $interrupt.logPath -Raw
    Assert-True (
        $interrupt.status -in @('completed', 'failed') -and
        $interruptLog -match 'finished with exit code' -and
        $interrupt.terminalControlState -eq 'released'
    ) 'The named Ctrl+C key should interrupt the foreground process without orphaning the managed host.'

    $orphan = (& $controller start -StateRoot $stateRoot -Name 'shared-terminal-orphan' `
        -Executable $pwsh -Arguments @('-NoProfile', '-Command', 'Write-Output "orphan-child-pid=$PID"; Start-Sleep -Seconds 30') `
        -Visible -SharedTerminal -Lifetime Persistent @backgroundOnlyParameters | Out-String) | ConvertFrom-Json
    $activeIds.Add($orphan.id)
    $orphan = Wait-JobStatus -Id $orphan.id -Expected @('running')
    $orphanControlFile = Get-ManagedJobControlFile -Id $orphan.id
    $orphanChildPid = Wait-PaneProcessId -Id $orphan.id -Pattern 'orphan-child-pid=(\d+)'
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
        -Visible -SharedTerminal @backgroundOnlyParameters | Out-String) | ConvertFrom-Json
    $activeIds.Add($turnOwned.id)
    $turnOwned = Wait-JobStatus -Id $turnOwned.id -Expected @('running')
    $turnChildPid = Wait-PaneProcessId -Id $turnOwned.id -Pattern 'turn-child-pid=(\d+)'
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
        -Visible -SharedTerminal -Lifetime Session @backgroundOnlyParameters | Out-String) | ConvertFrom-Json
    $activeIds.Add($sessionOwned.id)
    $sessionOwned = Wait-JobStatus -Id $sessionOwned.id -Expected @('running')
    $sessionChildPid = Wait-PaneProcessId -Id $sessionOwned.id -Pattern 'session-child-pid=(\d+)'
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
