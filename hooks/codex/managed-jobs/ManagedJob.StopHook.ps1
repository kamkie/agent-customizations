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
    $summary = (& $controller cleanup -OwnerAgent codex -OwnerSessionId $sessionId -CleanupLifetime Turn | Out-String) | ConvertFrom-Json
    $failures = @($summary.failures)
    if ($failures.Count -eq 0) { exit 0 }

    $details = @($failures | ForEach-Object {
        "$($_.name) (job $($_.id), PID $($_.hostPid)): $($_.error)"
    })
    $message = "Codex could not stop $($failures.Count) process tree(s) started for this turn: $($details -join ' | '). Resolve them before ending the turn."
    [ordered]@{
        decision = 'block'
        reason = $message
    } | ConvertTo-Json -Depth 5 -Compress
} catch {
    $message = "Codex could not verify end-of-turn process cleanup: $($_.Exception.Message)"
    [ordered]@{
        decision = 'block'
        reason = $message
    } | ConvertTo-Json -Depth 5 -Compress
}
