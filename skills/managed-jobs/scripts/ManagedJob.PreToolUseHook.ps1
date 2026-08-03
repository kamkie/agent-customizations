param([string]$ManagedHookId)

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

    $explicitBypass = $command -match '(?:codex-)?managed-jobs:\s*allow-direct'
    if ($explicitBypass) { exit 0 }

    $backgroundRequested = $payload.tool_input -isnot [string] -and
        $payload.tool_input.PSObject.Properties['run_in_background'] -and
        [bool]$payload.tool_input.run_in_background

    $patterns = @(
        '(?i)\bStart-Job\b',
        '(?i)\bStart-Process\b',
        '(?i)\bwt(?:\.exe)?\b.*\bnew-tab\b',
        '(?i)\bclaude(?:\.exe)?\b.*(?:\s-p\s|/review)',
        '(?i)(?:npm|pnpm|yarn)\s+(?:run\s+)?dev\b',
        '(?i)\bdotnet\s+watch\b',
        '(?i)\bgradlew(?:\.bat)?\s+bootRun\b',
        '(?i)\b(?:vite|webpack|tsc)\b.*--watch\b',
        '(?i)(?:--background|--bg)\b'
    )
    $matched = $patterns | Where-Object { $command -match $_ } | Select-Object -First 1

    # The controller exemption never covers a compound command that also uses a
    # raw detach primitive.
    $usesController = $command -match 'Invoke-ManagedJob\.ps1|managed-jobs[\\/]scripts'
    if ($usesController -and -not $matched) { exit 0 }

    $stateRoot = if ($env:MANAGED_JOBS_ROOT) { $env:MANAGED_JOBS_ROOT } else { Join-Path $HOME '.agent-customizations\managed-jobs' }
    $guardFile = Join-Path (Join-Path $stateRoot 'guard') 'denied-launches.json'
    $sha = [Security.Cryptography.SHA256]::Create()
    $fingerprint = [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($command.Trim())))
    $nowUtc = [datetime]::UtcNow
    $deniedEntries = @()
    if (Test-Path -LiteralPath $guardFile) {
        # Ticks survive the JSON round-trip; ConvertFrom-Json mangles ISO date strings.
        $deniedEntries = @(Get-Content -LiteralPath $guardFile -Raw | ConvertFrom-Json) | Where-Object {
            ($nowUtc.Ticks - [long]$_.deniedAtUtcTicks) -lt [TimeSpan]::FromHours(1).Ticks
        }
    }
    $retryOfDenied = $deniedEntries | Where-Object { [string]$_.fingerprint -eq $fingerprint } | Select-Object -First 1

    if (-not $matched -and -not $backgroundRequested -and -not $retryOfDenied) { exit 0 }

    $deniedEntries = @($deniedEntries | Where-Object { [string]$_.fingerprint -ne $fingerprint }) + @(
        [ordered]@{ fingerprint = $fingerprint; deniedAtUtcTicks = $nowUtc.Ticks }
    )
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $guardFile) -Force
    ConvertTo-Json @($deniedEntries) -Depth 4 | Set-Content -LiteralPath $guardFile -Encoding utf8

    $reason = if ($retryOfDenied -and -not $matched -and -not $backgroundRequested) {
        "This command was recently denied as a background or detached launch, and rerunning it in the foreground bounded by a tool-call timeout is not an acceptable substitute. Start it as a managed job via the managed-jobs skill and poll status/logs. If the user explicitly requested unmanaged execution, add the comment marker '# managed-jobs: allow-direct'."
    } else {
        "Long-running or detached command must use the managed-jobs skill so its PID, state, and logs survive agent restarts. Do not retry it as a foreground run bounded by a tool-call timeout; start a managed job and poll status/logs instead. If the user explicitly requested unmanaged execution, add the comment marker '# managed-jobs: allow-direct'."
    }
    [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = $reason
        }
    } | ConvertTo-Json -Depth 6 -Compress
} catch {
    [ordered]@{ systemMessage = "Managed-jobs command guard failed open: $($_.Exception.Message)" } | ConvertTo-Json -Compress
}
