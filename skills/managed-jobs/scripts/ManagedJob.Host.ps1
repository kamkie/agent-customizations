param(
    [Parameter(Mandatory)][string]$JobFile,
    [Parameter(Mandatory)][string]$LaunchFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ManagedJob.Common.ps1')
Set-ManagedJobStateRoot -Path (Split-Path -Parent (Split-Path -Parent $JobFile))

function Invoke-ManagedJobChildProcess {
    param(
        [Parameter(Mandatory)][Management.Automation.ApplicationInfo]$Application,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][scriptblock]$OnLine
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Application.Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Console]::OutputEncoding
    $startInfo.StandardErrorEncoding = [Console]::OutputEncoding
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add([string]$argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Failed to start $($Application.Source)." }
    try {
        $readers = @{
            out = @{ reader = $process.StandardOutput; task = $null }
            err = @{ reader = $process.StandardError; task = $null }
        }
        foreach ($key in @($readers.Keys)) { $readers[$key].task = $readers[$key].reader.ReadLineAsync() }
        $exitedAtUtc = $null
        $drainGrace = [timespan]::FromSeconds(2)
        while ($true) {
            $progressed = $false
            foreach ($key in @($readers.Keys)) {
                $entry = $readers[$key]
                if ($null -eq $entry.task) { continue }
                if (-not $entry.task.IsCompleted) { continue }
                $progressed = $true
                $line = $null
                try { $line = $entry.task.GetAwaiter().GetResult() } catch { $line = $null }
                if ($null -eq $line) {
                    $entry.task = $null
                } else {
                    & $OnLine $line
                    $entry.task = $entry.reader.ReadLineAsync()
                }
            }
            $pending = @($readers.Values | Where-Object { $null -ne $_.task } | ForEach-Object { $_.task })
            if ($pending.Count -eq 0) { break }
            if ($process.HasExited) {
                if ($null -eq $exitedAtUtc) { $exitedAtUtc = [datetime]::UtcNow }
                elseif (([datetime]::UtcNow - $exitedAtUtc) -gt $drainGrace) { break }
            }
            if (-not $progressed) {
                $null = [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]$pending, 200)
            }
        }
        $null = $process.WaitForExit(5000)
        return [int]$process.ExitCode
    } finally {
        $process.Dispose()
    }
}

$job = Read-ManagedJob -Path $JobFile
$keepTerminalOpen = [bool]$job.keepTerminalOpen
$sharedTerminal = $job.PSObject.Properties.Name -contains 'sharedTerminal' -and [bool]$job.sharedTerminal
$controlFile = if ($sharedTerminal) { Get-ManagedJobControlFile -Id $job.id } else { $null }
$controlCGuard = $null
$logDirectory = Split-Path -Parent $job.logPath
$null = New-Item -ItemType Directory -Path $logDirectory -Force
$writer = [IO.StreamWriter]::new($job.logPath, $true, [Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true

try {
    $containmentHandle = Enable-ManagedJobProcessContainment
    if ($job.PSObject.Properties.Name -contains 'processContainment') {
        $job.processContainment = 'windows-job-object-kill-on-close'
    } else {
        $job | Add-Member -NotePropertyName processContainment -NotePropertyValue 'windows-job-object-kill-on-close'
    }
    $launch = Read-ManagedJob -Path $LaunchFile
    Remove-Item -LiteralPath $LaunchFile -Force
    $hostSnapshot = Get-ProcessSnapshot -ProcessId $PID
    $job.hostPid = $PID
    $job.hostStartedAtUtc = $hostSnapshot.startTimeUtc
    if ($sharedTerminal) {
        $terminalSession = [guid]::Empty
        $terminalComClsid = [guid]::Empty
        if (-not [guid]::TryParse([string]$env:WT_SESSION, [ref]$terminalSession)) {
            throw 'The shared-terminal host did not receive a valid WT_SESSION.'
        }
        if (-not [guid]::TryParse([string]$env:WT_COM_CLSID, [ref]$terminalComClsid)) {
            throw 'The shared-terminal host did not receive a valid WT_COM_CLSID.'
        }
        $controlCGuard = Enable-ManagedJobHostControlCGuard
        $control = [ordered]@{
            schemaVersion = 1
            jobId = $job.id
            hostPid = $PID
            hostStartedAtUtc = $hostSnapshot.startTimeUtc
            wtSession = $terminalSession.ToString('D')
            wtComClsid = $terminalComClsid.ToString('B')
            registeredAtUtc = [datetime]::UtcNow.ToString('o')
        }
        Write-ManagedJson -Path $controlFile -Value $control
        $job.terminalControlState = 'registered'
    }
    $job.status = 'running'
    $job.startedAtUtc = [datetime]::UtcNow.ToString('o')
    Write-ManagedJob -Path $JobFile -Job $job

    if (-not (Test-Path -LiteralPath $job.workingDirectory -PathType Container)) {
        throw "Working directory does not exist: $($job.workingDirectory)"
    }
    Set-Location -LiteralPath $job.workingDirectory

    if ($launch.environment) {
        foreach ($property in $launch.environment.PSObject.Properties) {
            [Environment]::SetEnvironmentVariable($property.Name, [string]$property.Value, 'Process')
        }
    }

    # Arguments and environment values are deliberately omitted from durable logs.
    $header = "[$([datetime]::Now.ToString('s'))] managed-job $($job.id) starting executable $($job.executable)"
    Write-Host $header
    $writer.WriteLine($header)

    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($sharedTerminal) {
            # Interactive children must inherit the terminal streams directly.
            # Piping their output delays prompts that do not end in a newline and
            # rewrites terminal control sequences, corrupting the visible pane.
            & $launch.executable @($launch.arguments)
            $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
        } else {
            # Wait for the launched process to exit instead of for end-of-stream.
            # Windows descendants inherit the redirected handles, so a detached
            # grandchild that outlives the executable (for example a reusable
            # broker daemon) would otherwise hold the pipe open and leave the job
            # reported as running after the work has finished.
            $application = Get-Command -Name $launch.executable -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($application) {
                $exitCode = Invoke-ManagedJobChildProcess -Application $application -Arguments @($launch.arguments) -OnLine {
                    param($line)
                    Write-Host $line
                    $writer.WriteLine($line)
                }
            } else {
                # PowerShell commands run in-process and cannot leak the pipe.
                & $launch.executable @($launch.arguments) 2>&1 | ForEach-Object {
                    $line = $_.ToString()
                    Write-Host $line
                    $writer.WriteLine($line)
                }
                $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
            }
        }
    } finally {
        $ErrorActionPreference = $previousErrorPreference
    }

    $job = Read-ManagedJob -Path $JobFile
    $job.exitCode = $exitCode
    $job.status = if ($exitCode -eq 0) { 'completed' } else { 'failed' }
    if ($sharedTerminal) { $job.terminalControlState = 'released' }
    $job.finishedAtUtc = [datetime]::UtcNow.ToString('o')
    Write-ManagedJob -Path $JobFile -Job $job
    Unregister-ManagedJobOwnerReference -Job $job
    $footer = "[$([datetime]::Now.ToString('s'))] managed-job $($job.id) finished with exit code $exitCode"
    Write-Host $footer
    $writer.WriteLine($footer)
    if ($keepTerminalOpen) { return }
    exit $exitCode
} catch {
    $message = $_.Exception.Message
    try {
        $job = Read-ManagedJob -Path $JobFile
        $job.status = 'failed'
        $job.exitCode = 1
        if ($sharedTerminal) { $job.terminalControlState = 'released' }
        $job.error = $message
        $job.finishedAtUtc = [datetime]::UtcNow.ToString('o')
        Write-ManagedJob -Path $JobFile -Job $job
        Unregister-ManagedJobOwnerReference -Job $job
    } catch {}
    $line = "[$([datetime]::Now.ToString('s'))] managed-job failed: $message"
    Write-Host $line -ForegroundColor Red
    $writer.WriteLine($line)
    if ($keepTerminalOpen) { return }
    exit 1
} finally {
    if ($controlCGuard) { $controlCGuard.Dispose() }
    $writer.Dispose()
    if ($controlFile -and (Test-Path -LiteralPath $controlFile)) {
        Remove-Item -LiteralPath $controlFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $LaunchFile) { Remove-Item -LiteralPath $LaunchFile -Force -ErrorAction SilentlyContinue }
}
