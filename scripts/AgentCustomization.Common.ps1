Set-StrictMode -Version Latest

function Get-CustomizationRepositoryRoot {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function Get-CustomizationManifest {
    $path = Join-Path (Get-CustomizationRepositoryRoot) 'config\manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Customization manifest not found: $path"
    }

    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 2) {
        throw "Unsupported customization manifest schema: $($manifest.schemaVersion)"
    }
    return $manifest
}

function Get-CustomizationTargetNames {
    param([ValidateSet('All', 'Codex', 'Claude')][string]$Target = 'All')

    if ($Target -eq 'All') { return @('codex', 'claude') }
    return @($Target.ToLowerInvariant())
}

function Get-CustomizationTarget {
    param([Parameter(Mandatory)][string]$Name)

    $manifest = Get-CustomizationManifest
    $property = $manifest.targets.PSObject.Properties[$Name]
    if (-not $property) { throw "Unknown customization target: $Name" }
    return $property.Value
}

function Resolve-CustomizationHome {
    param(
        [Parameter(Mandatory)][string]$TargetName,
        [string]$HomePath
    )

    $target = Get-CustomizationTarget -Name $TargetName
    if ([string]::IsNullOrWhiteSpace($HomePath)) {
        $environmentValue = [Environment]::GetEnvironmentVariable([string]$target.homeEnvironmentVariable)
        $HomePath = if ($environmentValue) {
            $environmentValue
        } else {
            Join-Path $HOME ([string]$target.defaultHomeDirectory)
        }
    }

    return [IO.Path]::GetFullPath($HomePath)
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
    param(
        [Parameter(Mandatory)][string]$TargetName,
        [Parameter(Mandatory)][string]$HomePath
    )

    $repositoryRoot = Get-CustomizationRepositoryRoot
    $target = Get-CustomizationTarget -Name $TargetName
    $results = [Collections.Generic.List[object]]::new()

    $instructionSource = Join-Path $repositoryRoot ([string]$target.instructions.source)
    $instructionTarget = Join-Path $HomePath ([string]$target.instructions.destination)
    $instructionState = if (-not (Test-Path -LiteralPath $instructionTarget -PathType Leaf)) {
        'Missing'
    } elseif (Test-FilesEqual -Source $instructionSource -Target $instructionTarget) {
        'InSync'
    } else {
        'Different'
    }
    $results.Add([pscustomobject]@{
        Target = $TargetName
        Kind = 'Instructions'
        Name = [string]$target.instructions.destination
        RelativePath = [string]$target.instructions.destination
        State = $instructionState
    })

    foreach ($skillName in @($target.skills)) {
        $sourceRoot = Join-Path $repositoryRoot "skills\$skillName"
        $targetRoot = Join-Path $HomePath "skills\$skillName"
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
                Target = $TargetName
                Kind = 'Skill'
                Name = [string]$skillName
                RelativePath = $relativePath
                State = $state
            })
        }
    }

    return $results
}
