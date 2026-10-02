[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/AgentCustomization.Common.ps1')
$repositoryRoot = Get-CustomizationRepositoryRoot
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$sandbox = Join-Path $temporaryRoot ('skill-structure-test-' + [guid]::NewGuid().ToString('N'))
$assertions = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}

try {
    $fixture = Join-Path $sandbox 'repository'
    $null = New-Item -ItemType Directory -Path $fixture, (Join-Path $fixture 'scripts'), (Join-Path $fixture '.github')
    foreach ($directory in @('config', 'global', 'skills', 'hooks', 'tests')) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot $directory) -Destination $fixture -Recurse
    }
    foreach ($file in @('AGENTS.md', 'CLAUDE.md', 'README.md', 'LICENSE', 'SECURITY.md', '.github/CODEOWNERS', 'scripts/verify.ps1', 'scripts/AgentCustomization.Common.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot $file) -Destination (Join-Path $fixture $file)
    }
    $verifier = Join-Path $fixture 'scripts/verify.ps1'
    $output = @(& pwsh -NoProfile -File $verifier 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ('Shipped skills failed verification: ' + ($output -join ' '))

    $manifestPath = Join-Path $fixture 'config/manifest.json'
    $skillPath = Join-Path $fixture 'skills/dyslexia-friendly-formatter/SKILL.md'
    $referencePath = Join-Path $fixture 'skills/dyslexia-friendly-formatter/references/long.md'
    $cases = @(
        @{
            Name = 'reserved word in a Claude-deployed skill name'
            Path = $manifestPath
            Mutate = {
                param($text)
                $manifest = $text | ConvertFrom-Json
                $manifest.targets.claude.skills = @('claude-runner') + @($manifest.targets.claude.skills)
                $manifest | ConvertTo-Json -Depth 20
            }
            Expected = "Claude-deployed skill 'claude-runner' name contains a reserved word"
        },
        @{
            Name = 'oversized description'
            Path = $skillPath
            Mutate = { param($text) $text -replace '(?m)^description: .*$', ('description: ' + ('x' * 1025)) }
            Expected = "Skill 'dyslexia-friendly-formatter' description exceeds 1024 characters"
        },
        @{
            Name = 'XML tag in description'
            Path = $skillPath
            Mutate = { param($text) $text -replace '(?m)^(description: .*)$', '$1 <instructions>' }
            Expected = "Skill 'dyslexia-friendly-formatter' frontmatter contains an XML tag"
        },
        @{
            Name = 'uppercase name'
            Path = $skillPath
            Mutate = { param($text) $text -replace '(?m)^name: .*$', 'name: Dyslexia-Friendly-Formatter' }
            Expected = "does not match frontmatter name 'Dyslexia-Friendly-Formatter'"
        },
        @{
            Name = 'long reference without contents'
            Path = $referencePath
            Mutate = { param($text) "# Long`n`n## First`n" + (@(1..101 | ForEach-Object { "line $_" }) -join "`n") }
            Expected = "Reference over 100 lines needs '## Contents' as its first section: skills/dyslexia-friendly-formatter/references/long.md"
        }
    )
    foreach ($case in $cases) {
        Write-Host "Skill structure: rejecting $($case.Name)"
        $exists = Test-Path -LiteralPath $case.Path
        if (-not $exists) { $null = New-Item -ItemType Directory -Path (Split-Path -Parent $case.Path) -Force }
        $original = if ($exists) { [IO.File]::ReadAllText($case.Path) } else { '' }
        [IO.File]::WriteAllText($case.Path, (& $case.Mutate $original))
        $output = @(& pwsh -NoProfile -File $verifier 2>&1)
        Assert-True ($LASTEXITCODE -eq 1) "Verifier accepted $($case.Name)."
        # Write-Error wraps long messages with '|' gutters; compare the flattened text.
        $reported = ($output -join ' ') -replace '\s*\|\s*', ' ' -replace '\s+', ' '
        Assert-True ($reported -like "*$($case.Expected)*") "Verifier did not report $($case.Name): $reported"
        if ($exists) {
            [IO.File]::WriteAllText($case.Path, $original)
        } else {
            Remove-Item -LiteralPath (Split-Path -Parent $case.Path) -Recurse
        }
    }

    Write-Host 'Skill structure: accepting a long reference that opens with contents'
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $referencePath) -Force
    [IO.File]::WriteAllText($referencePath, "# Long`n`nIntro.`n`n## Contents`n`n- First`n`n## First`n" + (@(1..101 | ForEach-Object { "line $_" }) -join "`n"))
    $output = @(& pwsh -NoProfile -File $verifier 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ('Verifier rejected a long reference with contents: ' + ($output -join ' '))

    Write-Host "Skill structure tests: $assertions assertions passed"
} finally {
    if (Test-Path -LiteralPath $sandbox) {
        $resolved = (Resolve-Path -LiteralPath $sandbox).Path
        if (-not $resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Unexpected test cleanup target: $resolved" }
        Remove-Item -LiteralPath $resolved -Recurse
    }
}
