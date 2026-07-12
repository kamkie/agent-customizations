[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$CodexHome,
    [switch]$AllowDirty,
    [switch]$AllowNonMain
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexCustomization.Common.ps1')

$repositoryRoot = Get-CustomizationRepositoryRoot
$resolvedCodexHome = Resolve-CustomizationCodexHome -CodexHome $CodexHome
$manifest = Get-CustomizationManifest

& (Join-Path $PSScriptRoot 'verify.ps1')
$verificationSucceeded = $?
if (-not $verificationSucceeded) { throw 'Repository verification failed.' }

if (Test-Path -LiteralPath (Join-Path $repositoryRoot '.git')) {
    $dirty = @(& git -C $repositoryRoot status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect Git worktree state.' }
    if ($dirty.Count -gt 0 -and -not $AllowDirty) {
        throw 'Refusing to install from a dirty checkout. Commit or stash changes, or pass -AllowDirty explicitly.'
    }

    $branchOutput = @(& git -C $repositoryRoot branch --show-current)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the current Git branch.' }
    $branch = ($branchOutput -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($branch) -and -not $AllowNonMain) {
        throw 'Refusing to install from detached HEAD. Use a clean main checkout or pass -AllowNonMain explicitly.'
    }
    if (-not [string]::IsNullOrWhiteSpace($branch) -and $branch -ne 'main' -and -not $AllowNonMain) {
        throw "Refusing to install from branch '$branch'. Use a clean main checkout or pass -AllowNonMain explicitly."
    }
}

$status = @(Get-CustomizationStatus -CodexHome $resolvedCodexHome)
$drift = @($status | Where-Object State -ne 'InSync')
if ($drift.Count -eq 0) {
    Write-Host "Codex customizations are already in sync at $resolvedCodexHome"
    exit 0
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $resolvedCodexHome "customization-backups\$timestamp"
$skillsRoot = Join-Path $resolvedCodexHome 'skills'

if ($PSCmdlet.ShouldProcess($resolvedCodexHome, "Install $($drift.Count) customization change(s)")) {
    New-Item -ItemType Directory -Path $resolvedCodexHome, $skillsRoot, $backupRoot -Force | Out-Null

    $globalSource = Join-Path $repositoryRoot ([string]$manifest.globalAgents)
    $globalTarget = Join-Path $resolvedCodexHome 'AGENTS.md'
    $globalState = $status | Where-Object Kind -eq 'Global' | Select-Object -First 1
    if ($globalState.State -ne 'InSync') {
        if (Test-Path -LiteralPath $globalTarget -PathType Leaf) {
            Copy-Item -LiteralPath $globalTarget -Destination (Join-Path $backupRoot 'AGENTS.md') -Force
        }
        $temporaryGlobal = Join-Path $resolvedCodexHome ('.AGENTS.md.install-' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $globalSource -Destination $temporaryGlobal -Force
        Move-Item -LiteralPath $temporaryGlobal -Destination $globalTarget -Force
    }

    foreach ($skillName in @($manifest.skills)) {
        $skillDrift = @($status | Where-Object { $_.Kind -eq 'Skill' -and $_.Name -eq $skillName -and $_.State -ne 'InSync' })
        if ($skillDrift.Count -eq 0) { continue }

        $source = Join-Path $repositoryRoot "skills\$skillName"
        $target = Join-Path $skillsRoot $skillName
        $staging = Join-Path $skillsRoot ('.' + $skillName + '.install-' + [guid]::NewGuid().ToString('N'))
        $backup = Join-Path (Join-Path $backupRoot 'skills') $skillName

        Copy-Item -LiteralPath $source -Destination $staging -Recurse -Force
        try {
            if (Test-Path -LiteralPath $target -PathType Container) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
                Move-Item -LiteralPath $target -Destination $backup
            }
            Move-Item -LiteralPath $staging -Destination $target
        } catch {
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
            if (-not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $backup)) {
                Move-Item -LiteralPath $backup -Destination $target
            }
            throw
        }
    }
}

if ($WhatIfPreference) { exit 0 }

$remaining = @(Get-CustomizationStatus -CodexHome $resolvedCodexHome | Where-Object State -ne 'InSync')
if ($remaining.Count -gt 0) {
    throw "Installation completed with $($remaining.Count) remaining drift item(s)."
}

Write-Host "Installed Codex customizations to $resolvedCodexHome"
Write-Host "Previous files, when present, were backed up under $backupRoot"
