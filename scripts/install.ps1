[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('All', 'Codex', 'Claude')][string]$Target = 'All',
    [string]$CodexHome,
    [string]$ClaudeHome,
    [switch]$AllowDirty,
    [switch]$AllowNonMain
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AgentCustomization.Common.ps1')

$repositoryRoot = Get-CustomizationRepositoryRoot

& (Join-Path $PSScriptRoot 'verify.ps1')
if (-not $?) { throw 'Repository verification failed.' }

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

foreach ($targetName in Get-CustomizationTargetNames -Target $Target) {
    $targetConfig = Get-CustomizationTarget -Name $targetName
    $explicitHome = if ($targetName -eq 'codex') { $CodexHome } else { $ClaudeHome }
    $resolvedHome = Resolve-CustomizationHome -TargetName $targetName -HomePath $explicitHome
    $status = @(Get-CustomizationStatus -TargetName $targetName -HomePath $resolvedHome)
    $drift = @($status | Where-Object State -ne 'InSync')
    if ($drift.Count -eq 0) {
        Write-Host "$($targetConfig.displayName) customizations are already in sync at $resolvedHome"
        continue
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRoot = Join-Path $resolvedHome "customization-backups\$timestamp"
    $skillsRoot = Join-Path $resolvedHome 'skills'

    if ($PSCmdlet.ShouldProcess($resolvedHome, "Install $($drift.Count) $($targetConfig.displayName) customization change(s)")) {
        New-Item -ItemType Directory -Path $resolvedHome, $skillsRoot, $backupRoot -Force | Out-Null

        $instructionSource = Join-Path $repositoryRoot ([string]$targetConfig.instructions.source)
        $instructionTarget = Join-Path $resolvedHome ([string]$targetConfig.instructions.destination)
        $instructionState = $status | Where-Object Kind -eq 'Instructions' | Select-Object -First 1
        if ($instructionState.State -ne 'InSync') {
            if (Test-Path -LiteralPath $instructionTarget -PathType Leaf) {
                Copy-Item -LiteralPath $instructionTarget -Destination (Join-Path $backupRoot ([string]$targetConfig.instructions.destination)) -Force
            }
            $temporaryInstruction = Join-Path $resolvedHome ('.instructions.install-' + [guid]::NewGuid().ToString('N'))
            Copy-Item -LiteralPath $instructionSource -Destination $temporaryInstruction -Force
            Move-Item -LiteralPath $temporaryInstruction -Destination $instructionTarget -Force
        }

        foreach ($skillName in @($targetConfig.skills)) {
            $skillDrift = @($status | Where-Object { $_.Kind -eq 'Skill' -and $_.Name -eq $skillName -and $_.State -ne 'InSync' })
            if ($skillDrift.Count -eq 0) { continue }

            $source = Join-Path $repositoryRoot "skills\$skillName"
            $destination = Join-Path $skillsRoot $skillName
            $staging = Join-Path $skillsRoot ('.' + $skillName + '.install-' + [guid]::NewGuid().ToString('N'))
            $backup = Join-Path (Join-Path $backupRoot 'skills') $skillName

            Copy-Item -LiteralPath $source -Destination $staging -Recurse -Force
            try {
                if (Test-Path -LiteralPath $destination -PathType Container) {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
                    Move-Item -LiteralPath $destination -Destination $backup
                }
                Move-Item -LiteralPath $staging -Destination $destination
            } catch {
                if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
                if (-not (Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $backup)) {
                    Move-Item -LiteralPath $backup -Destination $destination
                }
                throw
            }
        }
    }

    if ($WhatIfPreference) { continue }

    $remaining = @(Get-CustomizationStatus -TargetName $targetName -HomePath $resolvedHome | Where-Object State -ne 'InSync')
    if ($remaining.Count -gt 0) {
        throw "Installation completed with $($remaining.Count) remaining $($targetConfig.displayName) drift item(s)."
    }

    Write-Host "Installed $($targetConfig.displayName) customizations to $resolvedHome"
    Write-Host "Previous files, when present, were backed up under $backupRoot"
}
