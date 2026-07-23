param([string]$ManagedHookId)

$ErrorActionPreference = 'Stop'
$payload = $null

function Write-CleanupFailure {
    param(
        [Parameter(Mandatory)][string]$Message,
        $HookPayload
    )

    $alreadyContinued = $HookPayload -and
        $HookPayload.PSObject.Properties.Name -contains 'stop_hook_active' -and
        [bool]$HookPayload.stop_hook_active
    if ($HookPayload -and -not $alreadyContinued) {
        [ordered]@{
            decision = 'block'
            reason = $Message
        } | ConvertTo-Json -Depth 5 -Compress
        return
    }

    [ordered]@{
        systemMessage = "$Message Automatic cleanup will not block the turn again; inspect and stop any affected process manually."
    } | ConvertTo-Json -Depth 5 -Compress
}

try {
    $payloadText = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($payloadText)) {
        $payload = $payloadText | ConvertFrom-Json
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
    $summary = (& $controller cleanup -OwnerAgent claude -OwnerSessionId $sessionId -CleanupLifetime Turn | Out-String) | ConvertFrom-Json
    $failures = @($summary.failures)
    if ($failures.Count -eq 0) { exit 0 }

    $details = @($failures | ForEach-Object {
        "$($_.name) (job $($_.id), PID $($_.hostPid)): $($_.error)"
    })
    $message = "Claude Code could not stop $($failures.Count) process tree(s) started for this turn: $($details -join ' | '). Resolve them before ending the turn."
    Write-CleanupFailure -Message $message -HookPayload $payload
} catch {
    $message = "Claude Code could not verify end-of-turn process cleanup: $($_.Exception.Message)"
    Write-CleanupFailure -Message $message -HookPayload $payload
}
