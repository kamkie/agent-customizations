param([string]$ManagedHookId)

$ErrorActionPreference = 'Stop'

# Split a command line into shell segments and each segment into tokens.
# Quotes group a token; `;`, `|`, `&`, `(`, `{`, and newlines end a segment.
# Each token records whether it was quoted so a shell command string can be
# inspected as a nested command line.
function Get-ShellSegments {
    param([string]$Text)
    $segments = [Collections.Generic.List[object]]::new()
    $tokens = [Collections.Generic.List[object]]::new()
    $buffer = [Text.StringBuilder]::new()
    $quote = [char]0
    $quoted = $false
    # Unquoted text before the first quote, so NAME="value" still reads as an
    # assignment even though its value is quoted.
    $unquotedPrefix = $null
    $chars = $Text.ToCharArray()
    # Iterate one past the end so a sentinel flushes the final token and segment.
    for ($i = 0; $i -le $chars.Length; $i++) {
        $atEnd = $i -eq $chars.Length
        $ch = if ($atEnd) { [char]0 } else { $chars[$i] }
        if (-not $atEnd -and $quote -ne [char]0) {
            if ($ch -eq $quote) { $quote = [char]0 } else { $null = $buffer.Append($ch) }
            continue
        }
        if (-not $atEnd -and ($ch -eq '"' -or $ch -eq "'")) {
            $quote = $ch
            if (-not $quoted) { $unquotedPrefix = $buffer.ToString() }
            $quoted = $true
            continue
        }
        $isSeparator = $atEnd -or ";|&(){}`r`n".IndexOf($ch) -ge 0
        if ($isSeparator -or [char]::IsWhiteSpace($ch)) {
            if ($buffer.Length -gt 0 -or $quoted) {
                $tokens.Add([pscustomobject]@{
                    text = $buffer.ToString()
                    quoted = $quoted
                    unquotedPrefix = if ($quoted) { $unquotedPrefix } else { $buffer.ToString() }
                })
                $null = $buffer.Clear()
                $quoted = $false
                $unquotedPrefix = $null
            }
            if ($isSeparator -and $tokens.Count -gt 0) {
                $segments.Add(@($tokens.ToArray()))
                $tokens.Clear()
            }
            continue
        }
        $null = $buffer.Append($ch)
    }
    return $segments.ToArray()
}

# True when any shell segment runs claude or claude.exe as its executable
# (after leading VAR=value assignments, `env`, or the PowerShell call operator)
# with a `-p` flag or a `/review` slash-command argument, including a command
# string handed to a shell with -c, -Command, or /c. Paths that merely contain
# "claude" and file names that merely contain "review" are not launches.
function Test-HeadlessClaudeLaunch {
    param([string]$Text, [int]$Depth = 0)
    if ($Depth -gt 3 -or [string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($segment in Get-ShellSegments -Text $Text) {
        $index = 0
        while ($index -lt $segment.Count) {
            $token = $segment[$index]
            $isAssignment = $token.unquotedPrefix -match '^[A-Za-z_][A-Za-z0-9_]*='
            if ($isAssignment -or (-not $token.quoted -and ($token.text -eq '&' -or $token.text -ieq 'env'))) {
                $index++
                continue
            }
            break
        }
        if ($index -ge $segment.Count) { continue }
        $executable = $segment[$index].text
        $baseName = $executable -replace '^.*[\\/]', ''
        $arguments = @($segment | Select-Object -Skip ($index + 1))
        if ($baseName -ieq 'claude' -or $baseName -ieq 'claude.exe') {
            foreach ($argument in $arguments) {
                if ($argument.text -eq '-p' -or $argument.text -match '^/review\b') { return $true }
            }
            continue
        }
        if ($baseName -imatch '^(?:bash|sh|zsh|pwsh|powershell|cmd)(?:\.exe)?$') {
            for ($i = 0; $i -lt $arguments.Count - 1; $i++) {
                if ($arguments[$i].text -imatch '^(?:-c|-Command|/c)$' -and (Test-HeadlessClaudeLaunch -Text $arguments[$i + 1].text -Depth ($Depth + 1))) {
                    return $true
                }
            }
        }
    }
    return $false
}

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
        '(?i)(?:npm|pnpm|yarn)\s+(?:run\s+)?dev\b',
        '(?i)\bdotnet\s+watch\b',
        '(?i)\bgradlew(?:\.bat)?\s+bootRun\b',
        '(?i)\b(?:vite|webpack|tsc)\b.*--watch\b',
        '(?i)(?:--background|--bg)\b'
    )
    $matched = $patterns | Where-Object { $command -match $_ } | Select-Object -First 1
    # A headless Claude launch is recognized by executable position, not by a
    # substring, so paths under .claude/ or names containing "review" pass.
    if (-not $matched -and (Test-HeadlessClaudeLaunch -Text $command)) { $matched = 'headless-claude' }

    # The controller exemption never covers a compound command that also uses a
    # raw detach primitive or a natively backgrounded tool call.
    $usesController = $command -match 'Invoke-ManagedJob\.ps1|managed-jobs[\\/]scripts'
    if ($usesController -and -not $matched -and -not $backgroundRequested) { exit 0 }

    # Retry memory is best-effort: a cache failure — including an unavailable
    # state-root drive — must weaken only retry detection, never a pattern or
    # background denial.
    $nowUtc = [datetime]::UtcNow
    $guardFile = $null
    $fingerprint = $null
    $deniedEntries = @()
    $guardMutex = $null
    $guardLocked = $false
    try {
        try {
            $stateRoot = if ($env:MANAGED_JOBS_ROOT) { $env:MANAGED_JOBS_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.agent-customizations\managed-jobs' }
            $guardFile = Join-Path (Join-Path $stateRoot 'guard') 'denied-launches.json'
            $sha = [Security.Cryptography.SHA256]::Create()
            $fingerprint = [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($command.Trim())))
            # Test seam, part 1: announce that this process is about to enter the
            # cache transaction so a regression test can wait for every peer. While
            # the seam is active the lock wait and the hold below stretch to the
            # same bound, so the rendezvous can never outlast a legitimate waiter.
            $guardWaitMilliseconds = 2000
            if ($env:MANAGED_JOBS_GUARD_BARRIER) {
                $guardWaitMilliseconds = 30000
                $null = New-Item -ItemType File -Path "$($env:MANAGED_JOBS_GUARD_BARRIER).ready-$PID" -Force
            }
            # Serialize the read/prune/update/replace transaction across concurrent
            # hook processes: without the lock two denials read the same old state
            # and the last writer erases the other's fingerprint. The wait is short
            # and fails open — on timeout this invocation still reads the cache but
            # skips its own write rather than overwrite another writer's entry.
            $guardLockName = 'Local\managed-jobs-guard-' + [Convert]::ToHexString(
                $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($guardFile.ToLowerInvariant()))).Substring(0, 32)
            $guardMutex = [Threading.Mutex]::new($false, $guardLockName)
            try {
                $guardLocked = $guardMutex.WaitOne($guardWaitMilliseconds)
            } catch [Threading.AbandonedMutexException] {
                # The previous holder exited without releasing; ownership transferred.
                $guardLocked = $true
            }
            if (Test-Path -LiteralPath $guardFile) {
                # Ticks survive the JSON round-trip; ConvertFrom-Json mangles ISO date strings.
                $deniedEntries = @(Get-Content -LiteralPath $guardFile -Raw | ConvertFrom-Json) | Where-Object {
                    ($nowUtc.Ticks - [long]$_.deniedAtUtcTicks) -lt [TimeSpan]::FromHours(1).Ticks
                }
            }
            # Test seam, part 2: hold (bounded by the same wait) between the cache read and the
            # write until the barrier file exists. Without serialization every
            # peer completes its read here before any write, which forces the
            # lost update; with the lock only the holder reaches this point.
            if ($env:MANAGED_JOBS_GUARD_BARRIER) {
                $barrierDeadline = [datetime]::UtcNow.AddMilliseconds($guardWaitMilliseconds)
                while (-not (Test-Path -LiteralPath $env:MANAGED_JOBS_GUARD_BARRIER) -and [datetime]::UtcNow -lt $barrierDeadline) {
                    Start-Sleep -Milliseconds 20
                }
            }
        } catch {
            $guardFile = $null
            $deniedEntries = @()
        }
        $retryOfDenied = if ($fingerprint) {
            $deniedEntries | Where-Object { [string]$_.fingerprint -eq $fingerprint } | Select-Object -First 1
        } else { $null }

        if (-not $matched -and -not $backgroundRequested -and -not $retryOfDenied) { exit 0 }

        $guardTempFile = $null
        try {
            if ($guardFile -and $fingerprint -and $guardLocked) {
                $deniedEntries = @($deniedEntries | Where-Object { [string]$_.fingerprint -ne $fingerprint }) + @(
                    [ordered]@{ fingerprint = $fingerprint; deniedAtUtcTicks = $nowUtc.Ticks }
                )
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $guardFile) -Force
                $guardTempFile = "$guardFile.$PID.tmp"
                ConvertTo-Json @($deniedEntries) -Depth 4 | Set-Content -LiteralPath $guardTempFile -Encoding utf8
                # Replace in one MoveFileEx call and retry briefly: Move-Item -Force
                # deletes then moves, so concurrent hook invocations collide.
                for ($attempt = 0; ; $attempt++) {
                    try {
                        [IO.File]::Move($guardTempFile, $guardFile, $true)
                        break
                    } catch [IO.IOException], [UnauthorizedAccessException] {
                        if ($attempt -ge 5) { throw }
                        Start-Sleep -Milliseconds (10 * [math]::Pow(2, $attempt))
                    }
                }
            }
        } catch {
            if ($guardTempFile -and (Test-Path -LiteralPath $guardTempFile)) {
                Remove-Item -LiteralPath $guardTempFile -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        if ($guardMutex) {
            if ($guardLocked) { try { $guardMutex.ReleaseMutex() } catch {} }
            $guardMutex.Dispose()
        }
    }

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
