[CmdletBinding()]
param(
    [string]$CodexHome,
    [switch]$SummaryOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexCustomization.Common.ps1')

$resolvedCodexHome = Resolve-CustomizationCodexHome -CodexHome $CodexHome
$status = @(Get-CustomizationStatus -CodexHome $resolvedCodexHome)
$drift = @($status | Where-Object State -ne 'InSync')

if (-not $SummaryOnly) {
    $status | Format-Table Kind, Name, RelativePath, State -AutoSize
}

[pscustomobject]@{
    codexHome = $resolvedCodexHome
    managedFiles = $status.Count
    inSync = @($status | Where-Object State -eq 'InSync').Count
    drift = $drift.Count
    missing = @($status | Where-Object State -eq 'Missing').Count
    different = @($status | Where-Object State -eq 'Different').Count
    extra = @($status | Where-Object State -eq 'Extra').Count
} | ConvertTo-Json -Depth 4

if ($drift.Count -gt 0) { exit 1 }
