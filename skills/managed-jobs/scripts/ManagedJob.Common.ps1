Set-StrictMode -Version Latest

$script:ManagedJobStateRoot = $null

function Set-ManagedJobStateRoot {
    param([string]$Path)
    $script:ManagedJobStateRoot = if ($Path) { [IO.Path]::GetFullPath($Path) } else { $null }
}

function Get-ManagedJobRoot {
    if ($script:ManagedJobStateRoot) {
        $root = $script:ManagedJobStateRoot
    } elseif ($env:MANAGED_JOBS_ROOT) {
        $root = [IO.Path]::GetFullPath($env:MANAGED_JOBS_ROOT)
    } else {
        $neutralRoot = Join-Path $HOME '.agent-customizations\managed-jobs'
        $legacyCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
        $legacyRoot = Join-Path $legacyCodexHome 'managed-jobs'
        # Preserve existing installations without copying or mutating their records. A new
        # installation uses the agent-neutral root unless an existing Codex registry exists.
        $root = if ((Test-Path -LiteralPath $legacyRoot -PathType Container) -and
            -not (Test-Path -LiteralPath $neutralRoot -PathType Container)) { $legacyRoot } else { $neutralRoot }
    }

    foreach ($directory in @('jobs', 'logs', 'launch')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $root $directory) -Force
    }
    return $root
}

function Get-ManagedJobFile {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') {
        throw "Invalid managed job id: $Id"
    }
    return Join-Path (Join-Path (Get-ManagedJobRoot) 'jobs') "$Id.json"
}

function Read-ManagedJob {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Managed job record not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-ManagedJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $directory = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $directory -Force
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-ManagedJob {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Job
    )
    Write-ManagedJson -Path $Path -Value $Job
}

function Get-ProcessSnapshot {
    param([Nullable[int]]$ProcessId)
    if (-not $ProcessId) { return $null }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return [pscustomobject]@{
            id = $process.Id
            startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
            processName = $process.ProcessName
        }
    } catch {
        return $null
    }
}

function Test-ManagedProcessIdentity {
    param(
        [Nullable[int]]$ProcessId,
        $ExpectedStartTimeUtc
    )
    $snapshot = Get-ProcessSnapshot -ProcessId $ProcessId
    if (-not $snapshot -or -not $ExpectedStartTimeUtc) { return $false }
    $expected = if ($ExpectedStartTimeUtc -is [datetime]) {
        $ExpectedStartTimeUtc.ToUniversalTime()
    } else {
        [datetimeoffset]::Parse([string]$ExpectedStartTimeUtc).UtcDateTime
    }
    $actual = [datetimeoffset]::Parse($snapshot.startTimeUtc).UtcDateTime
    return [math]::Abs(($actual - $expected).TotalSeconds) -lt 2
}

function Get-ManagedProcessIdentity {
    param($Job)
    $snapshot = Get-ProcessSnapshot -ProcessId $Job.hostPid
    [ordered]@{
        expectedPid = $Job.hostPid
        expectedStartTimeUtc = $Job.hostStartedAtUtc
        current = $snapshot
        matches = [bool]($snapshot -and (Test-ManagedProcessIdentity -ProcessId $Job.hostPid -ExpectedStartTimeUtc $Job.hostStartedAtUtc))
    }
}

function ConvertTo-SafeJobName {
    param([Parameter(Mandatory)][string]$Name)
    $slug = $Name.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
    $slug = $slug.Trim('-')
    if (-not $slug) { $slug = 'job' }
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).TrimEnd('-') }
    return $slug
}

function Assert-SecretSafeInvocation {
    param([string[]]$Arguments, [hashtable]$Environment)
    $secretName = '(?i)(secret|token|password|passwd|pwd|api[_-]?key|private[_-]?key|credential|auth|cookie)'
    $secretOption = '(?i)^--?[^=]*(?:secret|token|password|passwd|pwd|api[_-]?key|private[_-]?key|credential|auth|cookie)(?:=|$)'
    foreach ($key in $Environment.Keys) {
        if ([string]$key -match $secretName) {
            throw "Environment key '$key' appears secret-bearing. Configure it in the parent process or a credential store so managed-jobs only inherits it."
        }
    }
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = [string]$Arguments[$index]
        if ($argument -match $secretOption -or
            ($index -gt 0 -and [string]$Arguments[$index - 1] -match $secretOption) -or
            $argument -match '(?i)^[a-z][a-z0-9+.-]*://[^/@\s]+:[^/@\s]+@' -or
            $argument -match '(?i)(authorization\s*:\s*(?:bearer|basic)|bearer\s+[a-z0-9._~-]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)' -or
            $argument -match '(?i)(?:secret|token|password|passwd|pwd|api[_-]?key|private[_-]?key|credential|cookie)\s*[:=]\s*[^\s$]+') {
            throw 'Arguments appear secret-bearing. Use inherited environment configuration, standard input, a response file outside the registry, or the target tool credential store.'
        }
    }
}

function Get-InvocationFingerprint {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [hashtable]$Environment
    )
    $environmentNames = @($Environment.Keys | ForEach-Object { ([string]$_).ToUpperInvariant() } | Sort-Object)
    $canonical = [ordered]@{
        executable = $Executable.Trim().ToLowerInvariant()
        arguments = @($Arguments | ForEach-Object { [string]$_ })
        workingDirectory = ([IO.Path]::GetFullPath($WorkingDirectory)).TrimEnd('\').ToLowerInvariant()
        environmentNames = $environmentNames
    } | ConvertTo-Json -Depth 5 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}
