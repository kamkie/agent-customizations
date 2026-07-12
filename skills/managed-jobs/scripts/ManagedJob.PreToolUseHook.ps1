$ErrorActionPreference = 'Stop'

try {
    $payloadText = [Console]::In.ReadToEnd()
    if (-not $payloadText) { exit 0 }
    $payload = $payloadText | ConvertFrom-Json
    $command = if ($payload.tool_input -is [string]) {
        [string]$payload.tool_input
    } elseif ($payload.tool_input.command) {
        [string]$payload.tool_input.command
    } else {
        ''
    }
    if (-not $command) { exit 0 }

    $explicitBypass = $command -match 'codex-managed-jobs:\s*allow-direct'
    $usesController = $command -match 'Invoke-ManagedJob\.ps1|managed-jobs[\\/]scripts'
    if ($explicitBypass -or $usesController) { exit 0 }

    $patterns = @(
        '(?i)\bStart-Job\b',
        '(?i)\bStart-Process\b.*(?:-WindowStyle\s+Hidden|\bwt(?:\.exe)?\b)',
        '(?i)\bwt(?:\.exe)?\b.*\bnew-tab\b',
        '(?i)\bclaude(?:\.exe)?\b.*(?:\s-p\s|/review)',
        '(?i)(?:npm|pnpm|yarn)\s+(?:run\s+)?dev\b',
        '(?i)\bdotnet\s+watch\b',
        '(?i)\bgradlew(?:\.bat)?\s+bootRun\b',
        '(?i)\b(?:vite|webpack|tsc)\b.*--watch\b',
        '(?i)(?:--background|--bg)\b'
    )
    $matched = $patterns | Where-Object { $command -match $_ } | Select-Object -First 1
    if (-not $matched) { exit 0 }

    [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = "Long-running or detached command must use the managed-jobs skill so its PID, state, and logs survive Codex restarts. If the user explicitly requested unmanaged execution, add the comment marker '# codex-managed-jobs: allow-direct'."
        }
    } | ConvertTo-Json -Depth 6 -Compress
} catch {
    [ordered]@{ systemMessage = "Managed-jobs command guard failed open: $($_.Exception.Message)" } | ConvertTo-Json -Compress
}
