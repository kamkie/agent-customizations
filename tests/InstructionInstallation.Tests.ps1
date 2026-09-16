[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/AgentCustomization.Common.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('instruction-install-test-' + [guid]::NewGuid().ToString('N'))
$codexRoot = Join-Path $root 'codex'
$claudeRoot = Join-Path $root 'claude'
$codexFile = Join-Path $codexRoot 'AGENTS.md'
$claudeFile = Join-Path $claudeRoot 'CLAUDE.md'
$installer = Join-Path $PSScriptRoot '../scripts/install.ps1'
$assertions = 0
function Assert-True($condition, $message) {
    if (-not $condition) { throw $message }
    $script:assertions++
}
function Install-Expected($hashes, [string]$target = 'All', [switch]$Preview) {
    & $installer -Target $target -CodexHome $codexRoot -ClaudeHome $claudeRoot `
        -ExpectedInstructionHashes $hashes -AllowDirty -AllowNonMain -WhatIf:$Preview | Out-Null
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
    Assert-True ($null -eq $report.targets[0].instructionHash -and $report.targets[0].instructionHashError -like '*not a file*') 'Unavailable hash erased or misrepresented the status report.'
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
    # A single target requires only its own key; another target stays untouched.
    $claudeBefore = Get-CustomizationInstructionHash $claudeFile
    Install-Expected @{ codex = Get-CustomizationInstructionHash $codexFile } -target Codex
    Assert-True ((Get-CustomizationInstructionHash $claudeFile) -eq $claudeBefore) 'Single-target install changed the other target.'
    Write-Host "Instruction installation precondition tests: OK ($assertions assertions)"
} finally {
    $full = [IO.Path]::GetFullPath($root)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe installation test cleanup path.' }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
