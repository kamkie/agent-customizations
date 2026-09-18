[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/AgentCustomization.Common.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('instruction-install-test-' + [guid]::NewGuid().ToString('N'))
$codexRoot = Join-Path $root 'codex'
$claudeRoot = Join-Path $root 'claude'
$codexFile = Join-Path $codexRoot 'AGENTS.md'
$claudeFile = Join-Path $claudeRoot 'CLAUDE.md'
$codexTarget = Get-CustomizationTarget -Name 'codex'
$expectedModel = Get-CustomizationInstructionContent -Target $codexTarget -Kind modelInstructions
$modelInstalled = Join-Path $codexRoot ([string]$codexTarget.modelInstructions.destination)
$installer = Join-Path $PSScriptRoot '../scripts/install.ps1'
$assertions = 0
function Assert-True($condition, $message) {
    if (-not $condition) { throw $message }
    $script:assertions++
}
function Install-Expected($hashes, [string]$target = 'All', [switch]$Preview, [hashtable]$ModelHashes) {
    $modelArguments = @{}
    if ($target -ne 'Claude') {
        if (-not $PSBoundParameters.ContainsKey('ModelHashes')) {
            $ModelHashes = @{ codex = Get-CustomizationInstructionHash $modelInstalled }
        }
        $modelArguments.ExpectedModelInstructionHashes = $ModelHashes
    }
    & $installer -Target $target -CodexHome $codexRoot -ClaudeHome $claudeRoot `
        -ExpectedInstructionHashes $hashes @modelArguments -AllowDirty -AllowNonMain -WhatIf:$Preview | Out-Null
}
try {
    Assert-True ((Get-CustomizationInstructionHash $codexFile) -eq 'missing') 'Missing file hash differs.'
    Install-Expected @{ codex = 'missing'; claude = 'missing' } -Preview
    Assert-True (-not (Test-Path $root)) 'Preview wrote target state.'
    $nonFileHome = Join-Path $root 'nonfile'
    $null = New-Item -ItemType Directory -Path (Join-Path $nonFileHome 'AGENTS.md') -Force
    $statusOutput = @(& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../scripts/status.ps1') -Target Codex -CodexHome $nonFileHome -SummaryOnly)
    Assert-True ($LASTEXITCODE -eq 1) 'A non-file instruction target should still report drift.'
    $report = ($statusOutput -join "`n") | ConvertFrom-Json
    Assert-True ($report.instructionHashErrors -eq 1) 'Unavailable hash was not counted independently of ordinary drift.'
    Assert-True ($null -eq $report.targets[0].instructionHash -and $report.targets[0].instructionHashError -like '*not a file*') 'Unavailable hash erased or misrepresented the status report.'
    Assert-True ($report.targets[0].modelInstructionHash -eq 'missing' -and $report.modelInstructionHashErrors -eq 0) 'Absent model instructions should have a missing fingerprint without an error.'
    $nonFileModelHome = Join-Path $root 'nonfile-model'
    $null = New-Item -ItemType Directory -Path (Join-Path $nonFileModelHome $codexTarget.modelInstructions.destination)
    $statusOutput = @(& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../scripts/status.ps1') -Target Codex -CodexHome $nonFileModelHome -SummaryOnly)
    Assert-True ($LASTEXITCODE -eq 1) 'A non-file model instruction target should fail status.'
    $report = ($statusOutput -join "`n") | ConvertFrom-Json
    Assert-True ($report.modelInstructionHashErrors -eq 1 -and $report.instructionHashErrors -eq 0) 'Model hash errors were not counted separately.'
    Assert-True ($null -eq $report.targets[0].modelInstructionHash -and $report.targets[0].modelInstructionHashError -like '*not a file*') 'Unavailable model hash was reported as missing or erased the status report.'
    $null = New-Item -ItemType Directory -Path $codexRoot, $claudeRoot -Force
    [IO.File]::WriteAllText($codexFile, 'Reviewed local codex rule')
    [IO.File]::WriteAllText($claudeFile, 'Reviewed local claude rule')
    $hashes = @{ codex = Get-CustomizationInstructionHash $codexFile; claude = Get-CustomizationInstructionHash $claudeFile }
    [IO.File]::AppendAllText($claudeFile, '. A concurrent new rule.')
    $changedClaude = [IO.File]::ReadAllText($claudeFile)
    $rejected = $false
    try { Install-Expected $hashes } catch { $rejected = $_.Exception.Message -like 'Live instructions changed since review*' }
    Assert-True $rejected 'Stale second target was accepted.'
    Assert-True ((Get-CustomizationInstructionHash $codexFile) -eq $hashes.codex) 'First target was changed before second target precondition.'
    Assert-True ([IO.File]::ReadAllText($claudeFile) -ceq $changedClaude) 'Concurrent instruction was overwritten.'
    Assert-True (-not (Test-Path (Join-Path $codexRoot 'customization-backups'))) 'Rejected precondition created installation artifacts.'
    $rejected = $false
    try { Install-Expected @{ codex = 'missing'; claude = Get-CustomizationInstructionHash $claudeFile } } catch { $rejected = $_.Exception.Message -like 'Live instructions changed since review*' }
    Assert-True $rejected 'Previously missing file appearing was not detected.'
    foreach ($bad in @(@{ codex = $hashes.codex }, @{ codex = $hashes.codex; claude = 'invalid' }, @{ codex = $hashes.codex; claude = $hashes.claude; typo = 'missing' })) {
        $rejected = $false
        try { Install-Expected $bad } catch { $rejected = $_.Exception.Message -match 'ExpectedInstructionHashes|Invalid expected instruction hash' }
        Assert-True $rejected 'Incomplete or invalid precondition was accepted.'
    }
    $currentHashes = @{ codex = Get-CustomizationInstructionHash $codexFile; claude = Get-CustomizationInstructionHash $claudeFile }
    $rejected = $false
    try {
        & $installer -Target All -CodexHome $codexRoot -ClaudeHome $claudeRoot `
            -ExpectedInstructionHashes $currentHashes -AllowDirty -AllowNonMain | Out-Null
    } catch { $rejected = $_.Exception.Message -like 'ExpectedModelInstructionHashes must*' }
    Assert-True $rejected 'Guarded Codex installation accepted an omitted model snapshot.'
    $rejected = $false
    try {
        & $installer -Target Codex -CodexHome $codexRoot -ExpectedModelInstructionHashes @{ codex = 'missing' } `
            -AllowDirty -AllowNonMain | Out-Null
    } catch { $rejected = $_.Exception.Message -like 'ExpectedModelInstructionHashes requires*' }
    Assert-True $rejected 'Model-only guard accepted an omitted global instruction snapshot.'
    foreach ($badModel in @(@{}, @{ codex = 'invalid' }, @{ claude = 'missing' }, @{ codex = 'missing'; claude = 'missing' })) {
        $rejected = $false
        try { Install-Expected $currentHashes -ModelHashes $badModel } catch {
            $rejected = $_.Exception.Message -match 'ExpectedModelInstructionHashes|Invalid expected model instruction hash'
        }
        Assert-True $rejected 'Incomplete or invalid model precondition was accepted.'
    }
    [IO.File]::WriteAllText($modelInstalled, 'A model prompt created after review')
    $rejected = $false
    try { Install-Expected $currentHashes -ModelHashes @{ codex = 'missing' } -Preview } catch {
        $rejected = $_.Exception.Message -like 'Live instructions changed since review*'
    }
    Assert-True $rejected 'Preview missed a model file appearing after review.'
    $reviewedModelHash = Get-CustomizationInstructionHash $modelInstalled
    [IO.File]::AppendAllText($modelInstalled, '. A concurrent model rule.')
    $changedModelHash = Get-CustomizationInstructionHash $modelInstalled
    $rejected = $false
    try { Install-Expected $currentHashes -ModelHashes @{ codex = $reviewedModelHash } } catch {
        $rejected = $_.Exception.Message -like 'Live instructions changed since review*'
    }
    Assert-True $rejected 'Changed model prompt was accepted with a stale reviewed hash.'
    Assert-True ((Get-CustomizationInstructionHash $modelInstalled) -eq $changedModelHash) 'Concurrent model prompt was overwritten.'
    Assert-True ((Get-CustomizationInstructionHash $codexFile) -eq $currentHashes.codex -and (Get-CustomizationInstructionHash $claudeFile) -eq $currentHashes.claude) 'A stale model snapshot allowed another instruction file to change.'
    Assert-True (-not (Test-Path (Join-Path $codexRoot 'customization-backups')) -and -not (Test-Path (Join-Path $claudeRoot 'customization-backups'))) 'A stale model snapshot created installation artifacts.'
    Remove-Item -LiteralPath $modelInstalled
    $rejected = $false
    try { Install-Expected $currentHashes -ModelHashes @{ codex = $changedModelHash } } catch {
        $rejected = $_.Exception.Message -like 'Live instructions changed since review*'
    }
    Assert-True $rejected 'Model file removal after review was not detected.'
    # This fixture deliberately approves replacing both local rules; real use
    # must reconcile their meaning before taking this fresh snapshot.
    $hashes.claude = Get-CustomizationInstructionHash $claudeFile
    Install-Expected $hashes
    foreach ($entry in @(@{ name = 'codex'; home = $codexRoot; file = $codexFile }, @{ name = 'claude'; home = $claudeRoot; file = $claudeFile })) {
        $expected = Get-CustomizationInstructionContent -Target (Get-CustomizationTarget -Name $entry.name)
        Assert-True ([IO.File]::ReadAllText($entry.file) -ceq $expected) 'Matching snapshot did not install composed content.'
        $backups = @(Get-ChildItem (Join-Path $entry.home 'customization-backups') -Recurse -File | Where-Object Name -eq (Split-Path $entry.file -Leaf))
        Assert-True ($backups.Count -eq 1) 'Instruction backup missing.'
        Assert-True ((Get-CustomizationInstructionHash $backups[0].FullName) -eq $hashes[$entry.name]) 'Backup differs from accepted snapshot.'
    }
    # The Codex model-instructions replacement installs as one managed file and
    # reports as its own status kind.
    Assert-True ([IO.File]::ReadAllBytes($modelInstalled).Length -gt 0 -and ([IO.File]::ReadAllText($modelInstalled) -ceq $expectedModel)) 'Model instructions were not composed from the reviewed sources.'
    $modelStatus = Get-CustomizationStatus -TargetName 'codex' -HomePath $codexRoot | Where-Object Kind -eq 'ModelInstructions'
    Assert-True ($modelStatus.State -eq 'InSync') 'Installed model instructions should report InSync.'
    Add-Content -LiteralPath $modelInstalled -Value '# local drift' -Encoding utf8
    $modelStatus = Get-CustomizationStatus -TargetName 'codex' -HomePath $codexRoot | Where-Object Kind -eq 'ModelInstructions'
    Assert-True ($modelStatus.State -eq 'Different') 'Edited model instructions should report Different.'
    $acceptedModelHash = Get-CustomizationInstructionHash $modelInstalled
    Install-Expected @{ codex = Get-CustomizationInstructionHash $codexFile } -target Codex -ModelHashes @{ codex = $acceptedModelHash }
    Assert-True ([IO.File]::ReadAllText($modelInstalled) -ceq $expectedModel) 'Reinstall did not restore the reviewed model instructions.'
    $modelBackups = @(Get-ChildItem (Join-Path $codexRoot 'customization-backups') -Recurse -File | Where-Object Name -eq $codexTarget.modelInstructions.destination)
    Assert-True ($modelBackups.Count -eq 1 -and (Get-CustomizationInstructionHash $modelBackups[0].FullName) -eq $acceptedModelHash) 'Model backup differs from the accepted live snapshot.'
    $statusOutput = @(& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../scripts/status.ps1') -Target All -CodexHome $codexRoot -ClaudeHome $claudeRoot -SummaryOnly)
    Assert-True ($LASTEXITCODE -eq 0) 'Matching installed instructions should pass status.'
    $report = ($statusOutput -join "`n") | ConvertFrom-Json
    $codexSummary = $report.targets | Where-Object target -eq 'codex'
    $claudeSummary = $report.targets | Where-Object target -eq 'claude'
    Assert-True ($codexSummary.modelInstructionActivation -eq 'NotVerified') 'Synchronized files must not imply verified client activation.'
    Assert-True ($null -eq $claudeSummary.modelInstructionActivation) 'Model selection is not applicable to Claude.'
    Assert-True ($codexSummary.modelInstructionHash -eq (Get-CustomizationInstructionHash $modelInstalled)) 'Status model hash does not identify the installed content.'
    Assert-True ($null -eq $claudeSummary.modelInstructionHash -and $null -eq $claudeSummary.modelInstructionHashError) 'Target without a model prompt must report the model hash as not applicable.'
    # A single target requires only its own key; another target stays untouched.
    $claudeBefore = Get-CustomizationInstructionHash $claudeFile
    Install-Expected @{ codex = Get-CustomizationInstructionHash $codexFile } -target Codex
    Assert-True ((Get-CustomizationInstructionHash $claudeFile) -eq $claudeBefore) 'Single-target install changed the other target.'
    # A script-only hook update must not ask for re-trust; a changed definition must.
    function Install-CapturingWarnings($hashes) {
        $warnings = @()
        & $installer -Target All -CodexHome $codexRoot -ClaudeHome $claudeRoot `
            -ExpectedInstructionHashes $hashes -ExpectedModelInstructionHashes @{ codex = Get-CustomizationInstructionHash $modelInstalled } `
            -AllowDirty -AllowNonMain -WarningVariable warnings | Out-Null
        return @($warnings | ForEach-Object { [string]$_ })
    }
    $currentHashes = @{ codex = Get-CustomizationInstructionHash $codexFile; claude = Get-CustomizationInstructionHash $claudeFile }
    $synchronizedWarnings = Install-CapturingWarnings $currentHashes
    Assert-True ($synchronizedWarnings -match 'does not verify or activate') 'Already-synchronized Codex files must still disclose unverified activation.'
    $codexHookEntry = @((Get-CustomizationTarget -Name 'codex').hooks.entries)[0]
    $installedHookScript = Join-Path $codexRoot ([string]$codexHookEntry.script)
    Add-Content -LiteralPath $installedHookScript -Value '# script-only drift' -Encoding utf8
    $scriptOnlyWarnings = Install-CapturingWarnings $currentHashes
    Assert-True (-not ($scriptOnlyWarnings -match 'trust each definition')) 'A script-only hook update wrongly asked for Codex hook re-trust.'
    Assert-True (-not ($scriptOnlyWarnings -match 'captured hook snapshot')) 'A script-only hook update wrongly warned about the Claude hook snapshot.'
    $codexHooksPath = Join-Path $codexRoot ([string](Get-CustomizationTarget -Name 'codex').hooks.destination)
    $codexHooks = Get-Content -LiteralPath $codexHooksPath -Raw | ConvertFrom-Json
    $codexHooks.hooks.($codexHookEntry.event)[0].hooks[0].timeout = 99
    $codexHooks | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $codexHooksPath -Encoding utf8
    $definitionWarnings = Install-CapturingWarnings $currentHashes
    Assert-True ($definitionWarnings -match 'trust each definition') 'A changed Codex hook definition did not ask for re-trust.'
    # A first install into an existing Claude settings.json with unrelated settings
    # and no hooks property must report Missing, install, and keep those settings.
    $freshClaudeRoot = Join-Path $root 'claude-fresh'
    $null = New-Item -ItemType Directory -Path $freshClaudeRoot -Force
    $freshSettingsPath = Join-Path $freshClaudeRoot ([string](Get-CustomizationTarget -Name 'claude').hooks.destination)
    [ordered]@{ model = 'opus'; permissions = [ordered]@{ allow = @('Read') } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $freshSettingsPath -Encoding utf8
    $freshStatus = @(Get-CustomizationStatus -TargetName 'claude' -HomePath $freshClaudeRoot | Where-Object Kind -eq 'Hook')
    Assert-True ($freshStatus.Count -gt 0 -and @($freshStatus | Where-Object RegistrationState -ne 'Missing').Count -eq 0) 'Settings without a hooks property should report every hook registration as Missing.'
    $freshWarnings = @()
    & $installer -Target Claude -ClaudeHome $freshClaudeRoot -ExpectedInstructionHashes @{ claude = 'missing' } `
        -AllowDirty -AllowNonMain -WarningVariable freshWarnings | Out-Null
    $freshSettings = Get-Content -LiteralPath $freshSettingsPath -Raw | ConvertFrom-Json
    Assert-True ($freshSettings.model -eq 'opus' -and @($freshSettings.permissions.allow) -contains 'Read') 'First install dropped unrelated settings.'
    Assert-True ($freshSettings.PSObject.Properties.Name -contains 'hooks') 'First install did not create the hooks property.'
    Assert-True (@($freshWarnings | ForEach-Object { [string]$_ }) -match 'captured hook snapshot') 'A first-time hook registration should warn that a new session is needed.'
    # An empty settings object has no properties at all; it must behave the same way.
    $emptyClaudeRoot = Join-Path $root 'claude-empty'
    $null = New-Item -ItemType Directory -Path $emptyClaudeRoot -Force
    $emptySettingsPath = Join-Path $emptyClaudeRoot ([string](Get-CustomizationTarget -Name 'claude').hooks.destination)
    Set-Content -LiteralPath $emptySettingsPath -Value '{}' -Encoding utf8
    $emptyStatus = @(Get-CustomizationStatus -TargetName 'claude' -HomePath $emptyClaudeRoot | Where-Object Kind -eq 'Hook')
    Assert-True ($emptyStatus.Count -gt 0 -and @($emptyStatus | Where-Object RegistrationState -ne 'Missing').Count -eq 0) 'An empty settings object should report every hook registration as Missing.'
    $emptyWarnings = @()
    & $installer -Target Claude -ClaudeHome $emptyClaudeRoot -ExpectedInstructionHashes @{ claude = 'missing' } `
        -AllowDirty -AllowNonMain -WarningVariable emptyWarnings | Out-Null
    $emptySettings = Get-Content -LiteralPath $emptySettingsPath -Raw | ConvertFrom-Json
    Assert-True ($null -ne $emptySettings.PSObject.Properties['hooks']) 'First install into an empty settings object did not create the hooks property.'
    Assert-True (@($emptyWarnings | ForEach-Object { [string]$_ }) -match 'captured hook snapshot') 'A first-time registration into an empty settings object should warn that a new session is needed.'
    Write-Host "Instruction installation precondition tests: OK ($assertions assertions)"
} finally {
    $full = [IO.Path]::GetFullPath($root)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe installation test cleanup path.' }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
