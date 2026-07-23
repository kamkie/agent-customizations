$ErrorActionPreference = 'Stop'

try {
    $payloadText = [Console]::In.ReadToEnd()
    if (-not $payloadText) { exit 0 }
    $payload = $payloadText | ConvertFrom-Json
    $sessionId = if ($env:CODEX_THREAD_ID) {
        [string]$env:CODEX_THREAD_ID
    } else {
        [string]$payload.session_id
    }
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        throw 'Codex did not provide a session identifier for process cleanup.'
    }

    $codexHome = if ($env:CODEX_HOME) {
        [IO.Path]::GetFullPath($env:CODEX_HOME)
    } else {
        Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    $controller = Join-Path $codexHome 'skills\managed-jobs\scripts\Invoke-ManagedJob.ps1'
    $summary = (& $controller cleanup -OwnerAgent codex -OwnerSessionId $sessionId -CleanupLifetime Turn,Session | Out-String) | ConvertFrom-Json
    $failures = @($summary.failures)
    if ($failures.Count -eq 0) { exit 0 }

    $details = @($failures | ForEach-Object {
        "$($_.name) (job $($_.id), PID $($_.hostPid)): $($_.error)"
    })
    [Console]::Error.WriteLine(
        "Codex session cleanup could not stop $($failures.Count) process tree(s): $($details -join ' | ')."
    )
    exit 1
} catch {
    [Console]::Error.WriteLine("Codex session process cleanup failed: $($_.Exception.Message)")
    exit 1
}
