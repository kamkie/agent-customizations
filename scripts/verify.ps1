[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AgentCustomization.Common.ps1')

$repositoryRoot = Get-CustomizationRepositoryRoot
$manifest = Get-CustomizationManifest
$errors = [Collections.Generic.List[string]]::new()
$markdownFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

$requiredRepositoryFiles = @(
    'AGENTS.md',
    'CLAUDE.md',
    'README.md',
    'LICENSE',
    'SECURITY.md',
    'config\manifest.json',
    '.github\CODEOWNERS'
)
foreach ($relativePath in $requiredRepositoryFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $relativePath) -PathType Leaf)) {
        $errors.Add("Missing required repository file: $relativePath")
    }
}

$claudeRepositoryInstructions = Join-Path $repositoryRoot 'CLAUDE.md'
if (Test-Path -LiteralPath $claudeRepositoryInstructions -PathType Leaf) {
    $claudeImport = (Get-Content -LiteralPath $claudeRepositoryInstructions -Raw).Trim()
    if ($claudeImport -ne '@AGENTS.md') {
        $errors.Add('Root CLAUDE.md must contain only @AGENTS.md so AGENTS.md remains canonical')
    }
}

$codeownersPath = Join-Path $repositoryRoot '.github\CODEOWNERS'
if (Test-Path -LiteralPath $codeownersPath -PathType Leaf) {
    $codeowners = Get-Content -LiteralPath $codeownersPath -Raw
    if ($codeowners -notmatch '(?m)^\*\s+@kamkie\s*$') {
        $errors.Add('CODEOWNERS must request @kamkie for all repository changes')
    }
}

$targetNames = @($manifest.targets.PSObject.Properties.Name)
if ($targetNames.Count -eq 0) { $errors.Add('Manifest declares no targets') }
$declaredSkills = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$declaredPlugins = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$supportedHookEvents = @(
    'SessionStart', 'SessionEnd', 'SubagentStart', 'SubagentStop',
    'PreToolUse', 'PostToolUse', 'PermissionRequest',
    'UserPromptSubmit', 'PreCompact', 'PostCompact', 'Stop', 'StopFailure'
)
foreach ($targetName in $targetNames) {
    $target = $manifest.targets.PSObject.Properties[$targetName].Value
    foreach ($field in @('displayName', 'homeEnvironmentVariable', 'defaultHomeDirectory')) {
        if ([string]::IsNullOrWhiteSpace([string]$target.$field)) {
            $errors.Add("Target '$targetName' has no $field")
        }
    }

    $instructionsProperty = $target.PSObject.Properties['instructions']
    if (-not $instructionsProperty) {
        $errors.Add("Target '$targetName' has no instructions")
    } else {
        $instructions = $instructionsProperty.Value
        if ([string]::IsNullOrWhiteSpace([string]$instructions.destination)) {
            $errors.Add("Target '$targetName' instructions have no destination")
        }
        $sourcesProperty = $instructions.PSObject.Properties['sources']
        $instructionSources = if ($sourcesProperty) { @($sourcesProperty.Value) } else { @() }
        if ($instructionSources.Count -eq 0) {
            $errors.Add("Target '$targetName' instructions have no sources")
        }
        foreach ($source in $instructionSources) {
            if ([string]::IsNullOrWhiteSpace([string]$source)) {
                $errors.Add("Target '$targetName' instructions contain an empty source")
                continue
            }
            $instructionSource = Join-Path $repositoryRoot ([string]$source)
            if (-not (Test-Path -LiteralPath $instructionSource -PathType Leaf)) {
                $errors.Add("Target '$targetName' instruction source does not exist: $source")
            } elseif ([IO.Path]::GetExtension($instructionSource) -eq '.md') {
                [void]$markdownFiles.Add($instructionSource)
            }
        }
    }

    $modelInstructionsProperty = $target.PSObject.Properties['modelInstructions']
    if ($modelInstructionsProperty) {
        $modelInstructions = $modelInstructionsProperty.Value
        if ([string]::IsNullOrWhiteSpace([string]$modelInstructions.destination)) {
            $errors.Add("Target '$targetName' model instructions have no destination")
        }
        if ([string]::IsNullOrWhiteSpace([string]$modelInstructions.source)) {
            $errors.Add("Target '$targetName' model instructions have no source")
        } elseif (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot ([string]$modelInstructions.source)) -PathType Leaf)) {
            $errors.Add("Target '$targetName' model instruction source does not exist: $($modelInstructions.source)")
        } elseif ([IO.Path]::GetExtension([string]$modelInstructions.source) -eq '.md') {
            [void]$markdownFiles.Add((Join-Path $repositoryRoot ([string]$modelInstructions.source)))
        }
    }

    foreach ($skillName in @($target.skills)) {
        [void]$declaredSkills.Add([string]$skillName)
    }

    $pluginsProperty = $target.PSObject.Properties['plugins']
    if ($pluginsProperty) {
        $plugins = $pluginsProperty.Value
        if ([string]::IsNullOrWhiteSpace([string]$plugins.destination)) {
            $errors.Add("Target '$targetName' plugins have no destination")
        }
        foreach ($pluginName in @($plugins.entries)) {
            [void]$declaredPlugins.Add("$targetName/$pluginName")
            if ([string]$plugins.destination -eq 'skills' -and $pluginName -in @($target.skills)) {
                $errors.Add("Target '$targetName' plugin '$pluginName' collides with a skill of the same name")
            }
            $pluginManifest = Join-Path $repositoryRoot "plugins\$targetName\$pluginName\.claude-plugin\plugin.json"
            if (-not (Test-Path -LiteralPath $pluginManifest -PathType Leaf)) {
                $errors.Add("Plugin '$targetName/$pluginName' has no .claude-plugin/plugin.json")
                continue
            }
            try {
                $nameProperty = (Get-Content -LiteralPath $pluginManifest -Raw | ConvertFrom-Json).PSObject.Properties['name']
                $manifestName = if ($nameProperty) { [string]$nameProperty.Value } else { '' }
            } catch {
                $manifestName = ''
            }
            if ($manifestName -cne $pluginName) {
                $errors.Add("Plugin directory '$targetName/$pluginName' does not match plugin.json name '$manifestName'")
            }
        }
    }

    if ($target.PSObject.Properties.Name -contains 'hooks') {
        if ([string]::IsNullOrWhiteSpace([string]$target.hooks.destination)) {
            $errors.Add("Target '$targetName' hooks have no destination")
        }
        if ($target.hooks.PSObject.Properties.Name -contains 'handlerFormat' -and
            [string]$target.hooks.handlerFormat -notin @('codex', 'claude')) {
            $errors.Add("Target '$targetName' hooks have unsupported handlerFormat '$($target.hooks.handlerFormat)'")
        }
        $hookIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($target.hooks.entries)) {
            foreach ($field in @('id', 'event', 'source', 'script', 'timeout')) {
                if ([string]::IsNullOrWhiteSpace([string]$entry.$field)) {
                    $errors.Add("Target '$targetName' hook entry has no $field")
                }
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.id) -and -not $hookIds.Add([string]$entry.id)) {
                $errors.Add("Target '$targetName' has duplicate hook id '$($entry.id)'")
            }
            if ([int]$entry.timeout -le 0) {
                $errors.Add("Target '$targetName' hook '$($entry.id)' must have a positive timeout")
            }
            if ($entry.PSObject.Properties.Name -contains 'async' -and $entry.async -isnot [bool]) {
                $errors.Add("Target '$targetName' hook '$($entry.id)' async value must be boolean")
            }
            if ([string]$entry.event -notin $supportedHookEvents) {
                $errors.Add("Target '$targetName' hook '$($entry.id)' has unsupported event '$($entry.event)'")
            }
            if ([string]$entry.event -eq 'SessionEnd' -and [int]$entry.timeout -gt 3) {
                $errors.Add("Target '$targetName' SessionEnd hook '$($entry.id)' exceeds Codex's three-second limit")
            }
            $hookScript = Join-Path $repositoryRoot ([string]$entry.source)
            if (-not (Test-Path -LiteralPath $hookScript -PathType Leaf)) {
                $errors.Add("Target '$targetName' hook script does not exist: $($entry.script)")
            }
        }
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

    foreach ($file in Get-ChildItem -LiteralPath $skillRoot -Recurse -File -Filter '*.md') {
        [void]$markdownFiles.Add($file.FullName)
    }

    # Frontmatter limits follow Anthropic's skill authoring rules. The reserved
    # words apply only where Claude loads the skill; Codex-only skills may name
    # the Claude tool they wrap.
    try {
        $frontmatter = Get-SkillFrontmatter -Path $skillFile
    } catch {
        $errors.Add("Skill '$skillName' frontmatter is unsupported: $($_.Exception.Message)")
        $frontmatter = $null
    }
    $name = if ($frontmatter -and $frontmatter.PSObject.Properties['name']) { [string]$frontmatter.name } else { '' }
    $description = if ($frontmatter -and $frontmatter.PSObject.Properties['description']) { [string]$frontmatter.description } else { '' }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $errors.Add("Skill '$skillName' has no parseable frontmatter name")
    } elseif ($name -cne $skillName) {
        $errors.Add("Skill directory '$skillName' does not match frontmatter name '$name'")
    } elseif ($name.Length -gt 64 -or $name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        $errors.Add("Skill '$skillName' name must be at most 64 lowercase letters, digits, and single hyphens")
    } elseif ($skillName -in @($manifest.targets.claude.skills) -and $name -match 'anthropic|claude') {
        $errors.Add("Claude-deployed skill '$skillName' name contains a reserved word")
    }
    if ([string]::IsNullOrWhiteSpace($description)) {
        $errors.Add("Skill '$skillName' has no frontmatter description")
    } elseif ($description.Length -gt 1024) {
        $errors.Add("Skill '$skillName' description exceeds 1024 characters")
    }
    if ("$name $description" -match '<[A-Za-z/][^>]*>') {
        $errors.Add("Skill '$skillName' frontmatter contains an XML tag")
    }

    # Partial reads must still reveal a long reference's scope.
    $referenceRoot = Join-Path $skillRoot 'references'
    if (Test-Path -LiteralPath $referenceRoot -PathType Container) {
        foreach ($reference in Get-ChildItem -LiteralPath $referenceRoot -Recurse -File -Filter '*.md') {
            $lines = @(Get-Content -LiteralPath $reference.FullName)
            $firstSection = $lines | Where-Object { $_ -match '^## ' } | Select-Object -First 1
            if ($lines.Count -gt 100 -and $firstSection -notmatch '^## Contents\s*$') {
                $errors.Add("Reference over 100 lines needs '## Contents' as its first section: skills/$skillName/references/$($reference.Name)")
            }
        }
    }
}
foreach ($skillName in $actualSkills) {
    if (-not $declaredSkills.Contains($skillName)) {
        $errors.Add("Undeclared skill directory: $skillName")
    }
}
$pluginsRoot = Join-Path $repositoryRoot 'plugins'
if (Test-Path -LiteralPath $pluginsRoot -PathType Container) {
    foreach ($targetDirectory in Get-ChildItem -LiteralPath $pluginsRoot -Directory -Force) {
        foreach ($pluginDirectory in Get-ChildItem -LiteralPath $targetDirectory.FullName -Directory -Force) {
            $pluginKey = $targetDirectory.Name + '/' + $pluginDirectory.Name
            if (-not $declaredPlugins.Contains($pluginKey)) {
                $errors.Add("Undeclared plugin directory: plugins/$pluginKey")
            }
        }
    }
}

foreach ($file in $markdownFiles | Sort-Object) {
    foreach ($missing in Get-MissingMarkdownFileLink -Path $file) {
        $relativeSource = [IO.Path]::GetRelativePath($repositoryRoot, $missing.Source).Replace('\', '/')
        $errors.Add("Missing local Markdown link: $relativeSource -> $($missing.Target)")
    }
}

$managedRoots = @(
    (Join-Path $repositoryRoot 'global'),
    (Join-Path $repositoryRoot 'skills'),
    (Join-Path $repositoryRoot 'plugins'),
    (Join-Path $repositoryRoot 'hooks'),
    (Join-Path $repositoryRoot 'tests')
)
$forbiddenExtensions = @('.jsonl', '.log', '.key', '.pem')
$hazardPattern = '(?i)(gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|C:\\Users\\[^\\\s]+|[A-Z]:\\Projects\\)'
$managedFiles = @(foreach ($root in $managedRoots) {
    if (Test-Path -LiteralPath $root -PathType Container) {
        Get-ChildItem -LiteralPath $root -Recurse -File -Force
    }
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

$campaignPolicyTest = Join-Path $repositoryRoot 'tests\CampaignCustomization.Tests.ps1'
if (-not (Test-Path -LiteralPath $campaignPolicyTest -PathType Leaf)) {
    $errors.Add('Missing campaign customization policy test.')
} else {
    $campaignTestFailed = $false
    try {
        $campaignTestOutput = @(& pwsh -NoProfile -File $campaignPolicyTest 2>&1)
        $campaignTestFailed = $LASTEXITCODE -ne 0
    } catch {
        $campaignTestOutput = @($_.Exception.Message)
        $campaignTestFailed = $true
    }
    if ($campaignTestFailed) {
        $errors.Add('Campaign customization policy test failed: ' + ($campaignTestOutput -join ' '))
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
    plugins = $declaredPlugins.Count
    managedSourceFiles = $managedFiles.Count
    result = 'Valid'
} | ConvertTo-Json -Depth 4
