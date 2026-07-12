Set-StrictMode -Version Latest

function Get-CustomizationRepositoryRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function Resolve-CustomizationCodexHome {
    param([string]$CodexHome)

    if ([string]::IsNullOrWhiteSpace($CodexHome)) {
        $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    }

    return [IO.Path]::GetFullPath($CodexHome)
}

function Get-CustomizationManifest {
    $path = Join-Path (Get-CustomizationRepositoryRoot) 'config\manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Customization manifest not found: $path"
    }

    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1) {
        throw "Unsupported customization manifest schema: $($manifest.schemaVersion)"
    }
    return $manifest
}

function Get-RelativeFileMap {
    param([Parameter(Mandatory)][string]$Root)

    $map = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $map
    }

    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        $map[$relative] = $file.FullName
    }
    return $map
}

function Test-FilesEqual {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Source).Length -eq (Get-Item -LiteralPath $Target).Length -and
        (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash) {
        return $true
    }

    $sourceText = [IO.File]::ReadAllText($Source).Replace("`r`n", "`n")
    $targetText = [IO.File]::ReadAllText($Target).Replace("`r`n", "`n")
    return $sourceText -ceq $targetText
}

function Get-CustomizationStatus {
    param([string]$CodexHome)

    $repositoryRoot = Get-CustomizationRepositoryRoot
    $resolvedCodexHome = Resolve-CustomizationCodexHome -CodexHome $CodexHome
    $manifest = Get-CustomizationManifest
    $results = [Collections.Generic.List[object]]::new()

    $globalSource = Join-Path $repositoryRoot ([string]$manifest.globalAgents)
    $globalTarget = Join-Path $resolvedCodexHome 'AGENTS.md'
    $globalState = if (-not (Test-Path -LiteralPath $globalTarget -PathType Leaf)) {
        'Missing'
    } elseif (Test-FilesEqual -Source $globalSource -Target $globalTarget) {
        'InSync'
    } else {
        'Different'
    }
    $results.Add([pscustomobject]@{
        Kind = 'Global'
        Name = 'AGENTS.md'
        RelativePath = 'AGENTS.md'
        State = $globalState
    })

    foreach ($skillName in @($manifest.skills)) {
        $sourceRoot = Join-Path $repositoryRoot "skills\$skillName"
        $targetRoot = Join-Path $resolvedCodexHome "skills\$skillName"
        $sourceFiles = Get-RelativeFileMap -Root $sourceRoot
        $targetFiles = Get-RelativeFileMap -Root $targetRoot
        $relativePaths = @($sourceFiles.Keys) + @($targetFiles.Keys) | Sort-Object -Unique

        foreach ($relativePath in $relativePaths) {
            $sourceExists = $sourceFiles.ContainsKey($relativePath)
            $targetExists = $targetFiles.ContainsKey($relativePath)
            $state = if (-not $sourceExists) {
                'Extra'
            } elseif (-not $targetExists) {
                'Missing'
            } elseif (Test-FilesEqual -Source $sourceFiles[$relativePath] -Target $targetFiles[$relativePath]) {
                'InSync'
            } else {
                'Different'
            }

            $results.Add([pscustomobject]@{
                Kind = 'Skill'
                Name = [string]$skillName
                RelativePath = $relativePath
                State = $state
            })
        }
    }

    return $results
}
