param([string]$ManagedHookId)

$ErrorActionPreference = 'Stop'

try {
    $payloadText = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($payloadText)) {
        $payload = $payloadText | ConvertFrom-Json -NoEnumerate
        if ($payload -isnot [System.Management.Automation.PSCustomObject] -or
            $payload.session_id -isnot [string] -or
            [string]::IsNullOrWhiteSpace($payload.session_id)) {
            throw 'Codex hook payload must provide a nonblank string session_id for process cleanup.'
        }
        # The event owns cleanup; a nested session can inherit its parent's environment.
        $sessionId = $payload.session_id
    } else {
        $sessionId = $env:CODEX_THREAD_ID
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
