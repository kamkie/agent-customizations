$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..\scripts\Invoke-Lavish.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$dryRun = & pwsh -NoProfile -File $script -DryRun playbook comparison | ConvertFrom-Json
Assert-True ($dryRun.command -eq 'npx') 'Dry run must invoke npx.'
Assert-True ($dryRun.arguments[1] -eq 'lavish-axi@0.1.50') 'Dry run must pin lavish-axi 0.1.50.'
Assert-True ($dryRun.environment.LAVISH_AXI_TELEMETRY -eq 'off') 'Telemetry must be disabled.'
Assert-True ($dryRun.environment.LAVISH_AXI_HOST -eq '127.0.0.1') 'Host must be loopback.'

$blockedCases = @(
    @{ Arguments = @('share', 'artifact.html'); Pattern = 'requires -AllowPublish' },
    @{ Arguments = @('setup', 'hooks'); Pattern = 'requires -AllowSetup' },
    @{ Arguments = @('update'); Pattern = 'self-update is blocked' }
)

foreach ($case in $blockedCases) {
    $output = & pwsh -NoProfile -File $script @($case.Arguments) 2>&1
    Assert-True ($LASTEXITCODE -ne 0) "Expected '$($case.Arguments[0])' to be blocked."
    Assert-True (($output -join [Environment]::NewLine) -match $case.Pattern) "Missing guard message for '$($case.Arguments[0])'."
}

$allowedShare = & pwsh -NoProfile -File $script -AllowPublish -DryRun share artifact.html | ConvertFrom-Json
Assert-True ($allowedShare.arguments[-2] -eq 'share') 'Authorized share must preserve the operation.'

'Lavish wrapper tests passed.'
