param([string]$ManagedHookId)

$ErrorActionPreference = 'Stop'

try {
    $payloadText = [Console]::In.ReadToEnd()
    $payload = if ([string]::IsNullOrWhiteSpace($payloadText)) {
        $null
    } else {
        $payloadText | ConvertFrom-Json
    }
    # A nested Claude session inherits the outer session's environment, so the
    # hook payload is the authoritative session identity; the environment value
    # only covers an empty-stdin invocation.
    $sessionId = if ($payload -and $payload.session_id) {
        [string]$payload.session_id
    } elseif ($env:CLAUDE_CODE_SESSION_ID) {
        [string]$env:CLAUDE_CODE_SESSION_ID
    } else {
        $null
    }
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        throw 'Claude Code did not provide a session identifier for process cleanup.'
    }

    $claudeHome = if ($env:CLAUDE_CONFIG_DIR) {
        [IO.Path]::GetFullPath($env:CLAUDE_CONFIG_DIR)
    } else {
        Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    $controller = Join-Path $claudeHome 'skills\managed-jobs\scripts\Invoke-ManagedJob.ps1'
    $summary = (& $controller cleanup -OwnerAgent claude -OwnerSessionId $sessionId -CleanupLifetime Turn,Session | Out-String) | ConvertFrom-Json
    $failures = @($summary.failures)
    if ($failures.Count -eq 0) { exit 0 }

    $details = @($failures | ForEach-Object {
        "$($_.name) (job $($_.id), PID $($_.hostPid)): $($_.error)"
    })
    [Console]::Error.WriteLine(
        "Claude Code session cleanup could not stop $($failures.Count) process tree(s): $($details -join ' | ')."
    )
    exit 1
} catch {
    [Console]::Error.WriteLine("Claude Code session process cleanup failed: $($_.Exception.Message)")
    exit 1
}
