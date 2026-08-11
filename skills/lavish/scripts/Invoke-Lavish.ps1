[CmdletBinding()]
param(
    [switch]$AllowPublish,
    [switch]$AllowSetup,
    [switch]$AllowUpdate,
    [switch]$DryRun,

    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$LavishArgs
)

$ErrorActionPreference = 'Stop'
$package = 'lavish-axi@0.1.50'
$operation = if ($LavishArgs.Count -gt 0) { $LavishArgs[0].ToLowerInvariant() } else { '' }

if ($operation -eq 'share' -and -not $AllowPublish) {
    throw 'Lavish publishing requires -AllowPublish after explicit user authorization.'
}
if ($operation -eq 'setup' -and -not $AllowSetup) {
    throw 'Lavish setup requires -AllowSetup after explicit user authorization.'
}
if ($operation -eq 'update' -and -not $AllowUpdate) {
    throw 'Lavish self-update is blocked; update the reviewed pinned version instead.'
}

$childEnvironment = [ordered]@{
    LAVISH_AXI_TELEMETRY = 'off'
    LAVISH_AXI_HOST = '127.0.0.1'
    LAVISH_AXI_LINK_HOST = '127.0.0.1'
    LAVISH_AXI_ALLOWED_HOSTS = ''
}

if ($DryRun) {
    [pscustomobject]@{
        command = 'npx'
        arguments = @('-y', $package) + @($LavishArgs)
        environment = $childEnvironment
    } | ConvertTo-Json -Depth 4
    return
}

foreach ($entry in $childEnvironment.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
}

if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    throw 'npx is required. Install Node.js 22 or newer before using Lavish.'
}

& npx -y $package @LavishArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
