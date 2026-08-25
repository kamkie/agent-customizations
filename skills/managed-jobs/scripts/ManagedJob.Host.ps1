param(
    [Parameter(Mandatory)][string]$JobFile,
    [Parameter(Mandatory)][string]$LaunchFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ManagedJob.Common.ps1')
Set-ManagedJobStateRoot -Path (Split-Path -Parent (Split-Path -Parent $JobFile))

$job = Read-ManagedJob -Path $JobFile
$keepTerminalOpen = [bool]$job.keepTerminalOpen
$sharedTerminal = $job.PSObject.Properties.Name -contains 'sharedTerminal' -and [bool]$job.sharedTerminal
$controlFile = if ($sharedTerminal) { Get-ManagedJobControlFile -Id $job.id } else { $null }
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
        & $launch.executable @($launch.arguments) 2>&1 | ForEach-Object {
            $line = $_.ToString()
            Write-Host $line
            $writer.WriteLine($line)
        }
        $exitCode = if (Test-Path variable:LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
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
    $writer.Dispose()
    if ($controlFile -and (Test-Path -LiteralPath $controlFile)) {
        Remove-Item -LiteralPath $controlFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $LaunchFile) { Remove-Item -LiteralPath $LaunchFile -Force -ErrorAction SilentlyContinue }
}
