Set-StrictMode -Version Latest

function Get-ManagedJobRoot {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $root = Join-Path $codexHome 'managed-jobs'
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'jobs') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'logs') -Force
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

function Write-ManagedJob {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Job
    )
    $directory = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $directory -Force
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $Job | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-ProcessSnapshot {
    param([Nullable[int]]$ProcessId)
    if (-not $ProcessId) { return $null }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return [pscustomobject]@{
            Id = $process.Id
            StartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
            ProcessName = $process.ProcessName
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
    $actual = [datetimeoffset]::Parse($snapshot.StartTimeUtc).UtcDateTime
    return [math]::Abs(($actual - $expected).TotalSeconds) -lt 2
}

function ConvertTo-SafeJobName {
    param([Parameter(Mandatory)][string]$Name)
    $slug = $Name.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
    $slug = $slug.Trim('-')
    if (-not $slug) { $slug = 'job' }
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).TrimEnd('-') }
    return $slug
}
