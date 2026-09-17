[CmdletBinding()]
param(
    [ValidateSet('All', 'Codex', 'Claude')][string]$Target = 'All',
    [string]$CodexHome,
    [string]$ClaudeHome,
    [switch]$SummaryOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AgentCustomization.Common.ps1')

$allStatus = [Collections.Generic.List[object]]::new()
$summaries = [Collections.Generic.List[object]]::new()
foreach ($targetName in Get-CustomizationTargetNames -Target $Target) {
    $explicitHome = if ($targetName -eq 'codex') { $CodexHome } else { $ClaudeHome }
    $resolvedHome = Resolve-CustomizationHome -TargetName $targetName -HomePath $explicitHome
    $status = @(Get-CustomizationStatus -TargetName $targetName -HomePath $resolvedHome)
    foreach ($item in $status) { $allStatus.Add($item) }
    $drift = @($status | Where-Object State -ne 'InSync')
    $targetConfig = Get-CustomizationTarget -Name $targetName
    $instructionHash = $null
    $instructionHashError = $null
    try {
        $instructionHash = Get-CustomizationInstructionHash -Path (Join-Path $resolvedHome $targetConfig.instructions.destination)
    } catch {
        # An unavailable fingerprint must not erase the existing drift report.
        # Null cannot be passed as a valid installation precondition.
        $instructionHashError = $_.Exception.Message
    }
    $modelInstructionHash = $null
    $modelInstructionHashError = $null
    if ($null -ne $targetConfig.PSObject.Properties['modelInstructions']) {
        try {
            $modelInstructionHash = Get-CustomizationInstructionHash -Path (Join-Path $resolvedHome $targetConfig.modelInstructions.destination)
        } catch {
            $modelInstructionHashError = $_.Exception.Message
        }
    }
    $summaries.Add([pscustomobject]@{
        target = $targetName
        home = $resolvedHome
        managedFiles = $status.Count
        inSync = @($status | Where-Object State -eq 'InSync').Count
        drift = $drift.Count
        missing = @($status | Where-Object State -eq 'Missing').Count
        different = @($status | Where-Object State -eq 'Different').Count
        extra = @($status | Where-Object State -eq 'Extra').Count
        instructionHash = $instructionHash
        instructionHashError = $instructionHashError
        modelInstructionHash = $modelInstructionHash
        modelInstructionHashError = $modelInstructionHashError
    })
}

if (-not $SummaryOnly) {
    $allStatus | Format-Table Target, Kind, Name, RelativePath, State -AutoSize
}

[pscustomobject]@{
    targets = $summaries
    drift = @($allStatus | Where-Object State -ne 'InSync').Count
    instructionHashErrors = @($summaries | Where-Object { $_.instructionHashError }).Count
    modelInstructionHashErrors = @($summaries | Where-Object { $_.modelInstructionHashError }).Count
} | ConvertTo-Json -Depth 5

if (@($allStatus | Where-Object State -ne 'InSync').Count -gt 0 -or
    @($summaries | Where-Object { $_.instructionHashError -or $_.modelInstructionHashError }).Count -gt 0) { exit 1 }
