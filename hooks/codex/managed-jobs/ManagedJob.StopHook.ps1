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
    $sessionId = if ($env:CODEX_THREAD_ID) {
        [string]$env:CODEX_THREAD_ID
    } elseif ($payload) {
        [string]$payload.session_id
    } else {
        $null
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
    Write-CleanupFailure -Message $message -HookPayload $payload
} catch {
    $message = "Codex could not verify end-of-turn process cleanup: $($_.Exception.Message)"
    Write-CleanupFailure -Message $message -HookPayload $payload
}
