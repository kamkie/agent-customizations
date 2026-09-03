[CmdletBinding()]
param()

# Regression test for the retry-denial cache race in ManagedJob.PreToolUseHook:
# several hook processes denied at the same moment each read, prune, append,
# and replace guard/denied-launches.json. Without serialization the last writer
# erases the other fingerprints, so a later foreground retry of an erased
# command is allowed. Every concurrently denied command must still be denied on
# its foreground retry.
#
# The hook's MANAGED_JOBS_GUARD_BARRIER seam makes the contention deterministic:
# every hook process announces readiness before entering the transaction, then
# holds between its cache read and its write until the barrier file exists.
# Without serialization all six reads therefore complete before any write, so
# scheduling order cannot hide the lost update; with the lock only the holder
# reaches the hold and the rest queue on the mutex.

$ErrorActionPreference = 'Stop'
$hookScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ManagedJob.PreToolUseHook.ps1'
$pwsh = (Get-Process -Id $PID).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('managed-jobs-guard-cache-' + [guid]::NewGuid().ToString('N'))
$previousStateRoot = $env:MANAGED_JOBS_ROOT
$previousBarrier = $env:MANAGED_JOBS_GUARD_BARRIER
$barrierFile = Join-Path $testRoot 'barrier'
$assertionCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:assertionCount++
}

function Invoke-LaunchGuard {
    param([string]$Command, [bool]$Background)
    $toolInput = [ordered]@{ command = $Command }
    if ($Background) { $toolInput.run_in_background = $true }
    $payload = [ordered]@{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; tool_input = $toolInput } | ConvertTo-Json -Compress
    $output = ($payload | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hookScript | Out-String)
    if ([string]::IsNullOrWhiteSpace($output)) { return $null }
    return ($output | ConvertFrom-Json)
}

# Background-only commands: none match a launch pattern, so the foreground
# retry is denied only when the cache still holds the fingerprint.
$commandCount = 6
$commands = @(0..($commandCount - 1) | ForEach-Object { "python -m guard_cache_server_$_" })

$denyScript = {
    param([string]$Pwsh, [string]$HookScript, [string]$Command)
    $ErrorActionPreference = 'Stop'
    $payload = [ordered]@{
        hook_event_name = 'PreToolUse'; tool_name = 'Bash'
        tool_input = [ordered]@{ command = $Command; run_in_background = $true }
    } | ConvertTo-Json -Compress
    $output = ($payload | & $Pwsh -NoProfile -ExecutionPolicy Bypass -File $HookScript | Out-String)
    return [pscustomobject]@{ command = $Command; output = $output }
}

$pool = $null
$handles = @()
try {
    $null = New-Item -ItemType Directory -Path $testRoot -Force
    $env:MANAGED_JOBS_ROOT = $testRoot
    $env:MANAGED_JOBS_GUARD_BARRIER = $barrierFile

    $pool = [runspacefactory]::CreateRunspacePool(1, $commandCount)
    $pool.Open()
    foreach ($command in $commands) {
        $shell = [powershell]::Create()
        $shell.RunspacePool = $pool
        $null = $shell.AddScript($denyScript).AddArgument($pwsh).AddArgument($hookScript).AddArgument($command)
        $handles += [pscustomobject]@{ shell = $shell; async = $shell.BeginInvoke() }
    }
    # Wait until every hook process has entered the transaction, then release the
    # post-read hold so the writes follow the reads.
    $readyDeadline = [datetime]::UtcNow.AddSeconds(30)
    do {
        $ready = @(Get-ChildItem -LiteralPath $testRoot -Force -File -Filter 'barrier.ready-*').Count
        if ($ready -lt $commandCount) { Start-Sleep -Milliseconds 20 }
    } while ($ready -lt $commandCount -and [datetime]::UtcNow -lt $readyDeadline)
    Assert-True ($ready -eq $commandCount) "Every hook process should reach the guard barrier, found $ready of $commandCount."
    $null = New-Item -ItemType File -Path $barrierFile -Force

    $failures = [Collections.Generic.List[string]]::new()
    foreach ($handle in $handles) {
        try {
            foreach ($result in $handle.shell.EndInvoke($handle.async)) {
                $decision = $null
                try { $decision = $result.output | ConvertFrom-Json } catch {}
                if (-not $decision -or $decision.hookSpecificOutput.permissionDecision -ne 'deny') {
                    $failures.Add("concurrent background denial missing for '$($result.command)': $($result.output)")
                }
            }
        } catch {
            $failures.Add("runspace failed: $($_.Exception.Message)")
        }
        if ($handle.shell.HadErrors) {
            foreach ($record in $handle.shell.Streams.Error) { $failures.Add("runspace error: $record") }
        }
        $handle.shell.Dispose()
    }
    $handles = @()
    Assert-True ($failures.Count -eq 0) ("Every concurrent background launch must be denied:`n" + ($failures -join "`n"))

    $guardFile = Join-Path $testRoot 'guard\denied-launches.json'
    Assert-True (Test-Path -LiteralPath $guardFile -PathType Leaf) 'The concurrent denials should leave a retry cache behind.'
    $entries = @(Get-Content -LiteralPath $guardFile -Raw | ConvertFrom-Json)
    Assert-True ($entries.Count -eq $commandCount) "The cache should hold one fingerprint per concurrently denied command, found $($entries.Count) of $commandCount."
    $leftovers = @(Get-ChildItem -LiteralPath (Split-Path -Parent $guardFile) -Force -File | Where-Object { $_.Name -ne 'denied-launches.json' })
    Assert-True ($leftovers.Count -eq 0) ('Serialized cache writes must not leave temporary files behind: ' + (@($leftovers | ForEach-Object Name) -join ', '))

    foreach ($command in $commands) {
        $retry = Invoke-LaunchGuard -Command $command -Background $false
        Assert-True ($null -ne $retry -and $retry.hookSpecificOutput.permissionDecision -eq 'deny') "A foreground retry of '$command' must still be denied after concurrent denials."
        Assert-True ($retry.hookSpecificOutput.permissionDecisionReason -match 'recently denied') "The foreground retry of '$command' should be denied as a retry, not by pattern."
    }

    $unrelated = Invoke-LaunchGuard -Command 'python -m guard_cache_never_denied' -Background $false
    Assert-True ($null -eq $unrelated) 'A never-denied foreground command must stay allowed.'

    [pscustomobject]@{
        concurrentCommands = $commandCount
        assertions = $assertionCount
        result = 'Passed'
    } | ConvertTo-Json
} finally {
    foreach ($handle in $handles) { try { $handle.shell.Dispose() } catch {} }
    if ($pool) { $pool.Dispose() }
    if ($null -eq $previousStateRoot) {
        Remove-Item Env:MANAGED_JOBS_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:MANAGED_JOBS_ROOT = $previousStateRoot
    }
    if ($null -eq $previousBarrier) {
        Remove-Item Env:MANAGED_JOBS_GUARD_BARRIER -ErrorAction SilentlyContinue
    } else {
        $env:MANAGED_JOBS_GUARD_BARRIER = $previousBarrier
    }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
