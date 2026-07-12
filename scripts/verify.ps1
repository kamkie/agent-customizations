[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AgentCustomization.Common.ps1')

$repositoryRoot = Get-CustomizationRepositoryRoot
$manifest = Get-CustomizationManifest
$errors = [Collections.Generic.List[string]]::new()

$requiredRepositoryFiles = @(
    'AGENTS.md',
    'README.md',
    'LICENSE',
    'SECURITY.md',
    'config\manifest.json'
)
foreach ($relativePath in $requiredRepositoryFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $relativePath) -PathType Leaf)) {
        $errors.Add("Missing required repository file: $relativePath")
    }
}

$targetNames = @($manifest.targets.PSObject.Properties.Name)
if ($targetNames.Count -eq 0) { $errors.Add('Manifest declares no targets') }
$declaredSkills = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($targetName in $targetNames) {
    $target = $manifest.targets.PSObject.Properties[$targetName].Value
    foreach ($field in @('displayName', 'homeEnvironmentVariable', 'defaultHomeDirectory')) {
        if ([string]::IsNullOrWhiteSpace([string]$target.$field)) {
            $errors.Add("Target '$targetName' has no $field")
        }
    }

    foreach ($field in @('source', 'destination')) {
        if ([string]::IsNullOrWhiteSpace([string]$target.instructions.$field)) {
            $errors.Add("Target '$targetName' instructions have no $field")
        }
    }

    $instructionSource = Join-Path $repositoryRoot ([string]$target.instructions.source)
    if (-not (Test-Path -LiteralPath $instructionSource -PathType Leaf)) {
        $errors.Add("Target '$targetName' instruction source does not exist: $($target.instructions.source)")
    }

    foreach ($skillName in @($target.skills)) {
        [void]$declaredSkills.Add([string]$skillName)
    }
}

$actualSkills = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'skills') -Directory -Force |
    Select-Object -ExpandProperty Name)
foreach ($skillName in $declaredSkills) {
    $skillRoot = Join-Path $repositoryRoot "skills\$skillName"
    $skillFile = Join-Path $skillRoot 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
        $errors.Add("Skill '$skillName' has no SKILL.md")
        continue
    }

    $nameLine = Get-Content -LiteralPath $skillFile -TotalCount 20 |
        Select-String -Pattern '^name:\s*["'']?([^"'']+)["'']?\s*$' |
        Select-Object -First 1
    if (-not $nameLine) {
        $errors.Add("Skill '$skillName' has no parseable frontmatter name")
    } elseif ($nameLine.Matches[0].Groups[1].Value.Trim() -ne $skillName) {
        $errors.Add("Skill directory '$skillName' does not match frontmatter name '$($nameLine.Matches[0].Groups[1].Value.Trim())'")
    }
}
foreach ($skillName in $actualSkills) {
    if (-not $declaredSkills.Contains($skillName)) {
        $errors.Add("Undeclared skill directory: $skillName")
    }
}

$managedRoots = @(
    (Join-Path $repositoryRoot 'global'),
    (Join-Path $repositoryRoot 'skills')
)
$forbiddenExtensions = @('.jsonl', '.log', '.key', '.pem')
$hazardPattern = '(?i)(gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|C:\\Users\\[^\\\s]+|[A-Z]:\\Projects\\)'
$managedFiles = @(foreach ($root in $managedRoots) {
    Get-ChildItem -LiteralPath $root -Recurse -File -Force
})
foreach ($file in $managedFiles) {
    if ($file.Extension -in $forbiddenExtensions) {
        $errors.Add("Forbidden managed-source file type: $($file.FullName)")
        continue
    }

    $content = Get-Content -LiteralPath $file.FullName -Raw
    if ($content -match $hazardPattern) {
        $errors.Add("Possible credential or personal absolute path in: $($file.FullName)")
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}

[pscustomobject]@{
    repository = $repositoryRoot
    schemaVersion = $manifest.schemaVersion
    targets = $targetNames.Count
    skills = $declaredSkills.Count
    managedSourceFiles = $managedFiles.Count
    result = 'Valid'
} | ConvertTo-Json -Depth 4
