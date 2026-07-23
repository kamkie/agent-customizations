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
    if ($manifest.schemaVersion -ne 3) {
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

function Get-CustomizationHookCommand {
    param(
        [Parameter(Mandatory)][string]$HomePath,
        [Parameter(Mandatory)]$Entry,
        [switch]$WithoutManagedIdentity
    )

    $scriptPath = Join-Path $HomePath ([string]$Entry.script)
    $command = 'pwsh -NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
    if ($WithoutManagedIdentity) { return $command }
    return $command + ' -ManagedHookId "' + [string]$Entry.id + '"'
}

function Get-CustomizationHookHandlerFormat {
    param([Parameter(Mandatory)]$Target)

    if ($Target.PSObject.Properties.Name -contains 'hooks' -and
        $Target.hooks.PSObject.Properties.Name -contains 'handlerFormat') {
        return [string]$Target.hooks.handlerFormat
    }
    return 'codex'
}

function Test-CustomizationHookHandlerIdentity {
    param(
        [Parameter(Mandatory)]$Handler,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$HomePath
    )

    $expectedCommand = Get-CustomizationHookCommand -HomePath $HomePath -Entry $Entry
    $legacyCommand = Get-CustomizationHookCommand -HomePath $HomePath -Entry $Entry -WithoutManagedIdentity
    $identitySuffix = ' -ManagedHookId "' + [string]$Entry.id + '"'
    foreach ($field in @('command', 'commandWindows')) {
        $property = $Handler.PSObject.Properties[$field]
        if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { continue }
        $command = [string]$property.Value
        if ($command.Equals($expectedCommand, [StringComparison]::OrdinalIgnoreCase) -or
            $command.Equals($legacyCommand, [StringComparison]::OrdinalIgnoreCase) -or
            $command.EndsWith($identitySuffix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-CustomizationHookDefinition {
    param(
        [Parameter(Mandatory)]$Group,
        [Parameter(Mandatory)]$Handler,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$HomePath,
        [ValidateSet('codex', 'claude')][string]$Format = 'codex'
    )

    $expectedMatcher = if ($Entry.PSObject.Properties.Name -contains 'matcher') { [string]$Entry.matcher } else { '' }
    $actualMatcher = if ($Group.PSObject.Properties.Name -contains 'matcher') { [string]$Group.matcher } else { '' }
    if ($actualMatcher -cne $expectedMatcher) { return $false }

    $expectedCommand = Get-CustomizationHookCommand -HomePath $HomePath -Entry $Entry
    if ($Format -eq 'claude') {
        # Claude Code hook handlers carry only type/command/timeout; extra
        # fields would fail Claude's settings validation, so their presence is
        # drift that repair must rewrite.
        foreach ($field in @('commandWindows', 'statusMessage')) {
            if ($Handler.PSObject.Properties[$field]) { return $false }
        }
        $commandProperty = $Handler.PSObject.Properties['command']
        $timeoutProperty = $Handler.PSObject.Properties['timeout']
        if (-not $commandProperty -or -not $timeoutProperty) { return $false }
        return ([string]$Handler.type -ceq 'command' -and
            [string]$commandProperty.Value -ceq $expectedCommand -and
            [int]$timeoutProperty.Value -eq [int]$Entry.timeout)
    }

    if ([string]$Handler.type -cne 'command' -or
        [string]$Handler.command -cne $expectedCommand -or
        [string]$Handler.commandWindows -cne $expectedCommand -or
        [int]$Handler.timeout -ne [int]$Entry.timeout) {
        return $false
    }

    $expectedStatus = if ($Entry.PSObject.Properties.Name -contains 'statusMessage') { [string]$Entry.statusMessage } else { '' }
    $actualStatus = if ($Handler.PSObject.Properties.Name -contains 'statusMessage') { [string]$Handler.statusMessage } else { '' }
    return $actualStatus -ceq $expectedStatus
}

function Get-CustomizationHookState {
    param(
        [Parameter(Mandatory)][string]$HooksPath,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$HomePath,
        [ValidateSet('codex', 'claude')][string]$Format = 'codex'
    )

    if (-not (Test-Path -LiteralPath $HooksPath -PathType Leaf)) { return 'Missing' }
    try {
        $config = Get-Content -LiteralPath $HooksPath -Raw | ConvertFrom-Json
    } catch {
        return 'Different'
    }

    if (-not $config -or -not $config.hooks) { return 'Missing' }
    $candidateCount = 0
    $exactCount = 0
    foreach ($eventProperty in $config.hooks.PSObject.Properties) {
        foreach ($group in @($eventProperty.Value)) {
            foreach ($handler in @($group.hooks)) {
                if (-not (Test-CustomizationHookHandlerIdentity -Handler $handler -Entry $Entry -HomePath $HomePath)) { continue }
                $candidateCount++
                if ($eventProperty.Name -ceq [string]$Entry.event -and
                    (Test-CustomizationHookDefinition -Group $group -Handler $handler -Entry $Entry -HomePath $HomePath -Format $Format)) {
                    $exactCount++
                }
            }
        }
    }

    if ($candidateCount -eq 0) { return 'Missing' }
    if ($candidateCount -eq 1 -and $exactCount -eq 1) { return 'InSync' }
    return 'Different'
}

function Test-CustomizationHookHandlerMapIdentity {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Handler,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$HomePath
    )

    $asObject = [pscustomobject]$Handler
    return Test-CustomizationHookHandlerIdentity -Handler $asObject -Entry $Entry -HomePath $HomePath
}

function Update-CustomizationHookFile {
    param(
        [Parameter(Mandatory)][string]$HooksPath,
        [Parameter(Mandatory)][object[]]$Entries,
        [Parameter(Mandatory)][string]$HomePath,
        [ValidateSet('codex', 'claude')][string]$Format = 'codex'
    )

    $config = if (Test-Path -LiteralPath $HooksPath -PathType Leaf) {
        Get-Content -LiteralPath $HooksPath -Raw | ConvertFrom-Json -AsHashtable
    } else {
        [ordered]@{}
    }
    if ($config -isnot [Collections.IDictionary]) {
        throw "Refusing to update a hook file whose root is not an object: $HooksPath"
    }
    if (-not $config.Contains('hooks')) {
        $config['hooks'] = [ordered]@{}
    } elseif ($config['hooks'] -isnot [Collections.IDictionary]) {
        throw "Refusing to replace a hook file whose 'hooks' value is not an object: $HooksPath"
    }

    foreach ($entry in $Entries) {
        $event = [string]$entry.event
        foreach ($configuredEvent in @($config['hooks'].Keys)) {
            $updatedConfiguredGroups = [Collections.Generic.List[object]]::new()
            foreach ($group in @($config['hooks'][$configuredEvent])) {
                if ($group -isnot [Collections.IDictionary]) {
                    $updatedConfiguredGroups.Add($group)
                    continue
                }
                $remainingHandlers = @(
                    foreach ($handler in @($group['hooks'])) {
                        if ($handler -isnot [Collections.IDictionary] -or
                            -not (Test-CustomizationHookHandlerMapIdentity -Handler $handler -Entry $entry -HomePath $HomePath)) {
                            $handler
                        }
                    }
                )
                if ($remainingHandlers.Count -gt 0) {
                    $group['hooks'] = $remainingHandlers
                    $updatedConfiguredGroups.Add($group)
                }
            }
            if ($updatedConfiguredGroups.Count -eq 0) {
                $config['hooks'].Remove($configuredEvent)
            } else {
                $config['hooks'][$configuredEvent] = $updatedConfiguredGroups.ToArray()
            }
        }

        $command = Get-CustomizationHookCommand -HomePath $HomePath -Entry $entry
        $handler = [ordered]@{
            type = 'command'
            command = $command
        }
        if ($Format -ne 'claude') {
            $handler['commandWindows'] = $command
        }
        $handler['timeout'] = [int]$entry.timeout
        if ($Format -ne 'claude' -and $entry.PSObject.Properties.Name -contains 'statusMessage') {
            $handler['statusMessage'] = [string]$entry.statusMessage
        }
        $newGroup = [ordered]@{}
        if ($entry.PSObject.Properties.Name -contains 'matcher') {
            $newGroup['matcher'] = [string]$entry.matcher
        }
        $newGroup['hooks'] = @($handler)
        $updatedGroups = [Collections.Generic.List[object]]::new()
        if ($config['hooks'].Contains($event)) {
            foreach ($group in @($config['hooks'][$event])) { $updatedGroups.Add($group) }
        }
        $updatedGroups.Add($newGroup)
        $config['hooks'][$event] = $updatedGroups.ToArray()
    }

    $directory = Split-Path -Parent $HooksPath
    $null = New-Item -ItemType Directory -Path $directory -Force
    $temporary = Join-Path $directory ('.hooks.install-' + [guid]::NewGuid().ToString('N') + '.json')
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $HooksPath -Force
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

    if ($target.PSObject.Properties.Name -contains 'hooks') {
        $hooksPath = Join-Path $HomePath ([string]$target.hooks.destination)
        $hookFormat = Get-CustomizationHookHandlerFormat -Target $target
        foreach ($entry in @($target.hooks.entries)) {
            $hookSource = Join-Path $repositoryRoot ([string]$entry.source)
            $hookTarget = Join-Path $HomePath ([string]$entry.script)
            $hookState = if (-not (Test-Path -LiteralPath $hookTarget -PathType Leaf)) {
                'Missing'
            } elseif (-not (Test-FilesEqual -Source $hookSource -Target $hookTarget)) {
                'Different'
            } else {
                Get-CustomizationHookState -HooksPath $hooksPath -Entry $entry -HomePath $HomePath -Format $hookFormat
            }
            $results.Add([pscustomobject]@{
                Target = $TargetName
                Kind = 'Hook'
                Name = [string]$entry.id
                RelativePath = ([string]$target.hooks.destination) + '#' + ([string]$entry.event)
                State = $hookState
            })
        }
    }

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
