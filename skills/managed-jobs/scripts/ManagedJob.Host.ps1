param(
    [Parameter(Mandatory)][string]$JobFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ManagedJob.Common.ps1')

$job = Read-ManagedJob -Path $JobFile
$hostSnapshot = Get-ProcessSnapshot -ProcessId $PID
$job.hostPid = $PID
$job.hostStartedAtUtc = $hostSnapshot.StartTimeUtc
$job.status = 'running'
$job.startedAtUtc = [datetime]::UtcNow.ToString('o')
Write-ManagedJob -Path $JobFile -Job $job

$logDirectory = Split-Path -Parent $job.logPath
$null = New-Item -ItemType Directory -Path $logDirectory -Force
$writer = [IO.StreamWriter]::new($job.logPath, $true, [Text.UTF8Encoding]::new($false))
$writer.AutoFlush = $true

try {
    if (-not (Test-Path -LiteralPath $job.workingDirectory -PathType Container)) {
        throw "Working directory does not exist: $($job.workingDirectory)"
    }
    Set-Location -LiteralPath $job.workingDirectory

    if ($job.environment) {
        foreach ($property in $job.environment.PSObject.Properties) {
            [Environment]::SetEnvironmentVariable($property.Name, [string]$property.Value, 'Process')
        }
    }

    $header = "[$([datetime]::Now.ToString('s'))] managed-job $($job.id) starting: $($job.executable) $($job.arguments -join ' ')"
    Write-Host $header
    $writer.WriteLine($header)

    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $job.executable @($job.arguments) 2>&1 | ForEach-Object {
            $line = $_.ToString()
            Write-Host $line
            $writer.WriteLine($line)
        }
        $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }
    } finally {
        $ErrorActionPreference = $previousErrorPreference
    }

    $job = Read-ManagedJob -Path $JobFile
    $job.exitCode = $exitCode
    $job.status = if ($exitCode -eq 0) { 'completed' } else { 'failed' }
    $job.finishedAtUtc = [datetime]::UtcNow.ToString('o')
    Write-ManagedJob -Path $JobFile -Job $job
    $footer = "[$([datetime]::Now.ToString('s'))] managed-job $($job.id) finished with exit code $exitCode"
    Write-Host $footer
    $writer.WriteLine($footer)
    exit $exitCode
} catch {
    $message = $_.Exception.Message
    try {
        $job = Read-ManagedJob -Path $JobFile
        $job.status = 'failed'
        $job.exitCode = 1
        $job.error = $message
        $job.finishedAtUtc = [datetime]::UtcNow.ToString('o')
        Write-ManagedJob -Path $JobFile -Job $job
    } catch {}
    $line = "[$([datetime]::Now.ToString('s'))] managed-job failed: $message"
    Write-Host $line -ForegroundColor Red
    $writer.WriteLine($line)
    exit 1
} finally {
    $writer.Dispose()
}
