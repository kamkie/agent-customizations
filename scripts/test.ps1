[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$sandbox = Join-Path $temporaryRoot ('agent-customizations-test-' + [guid]::NewGuid().ToString('N'))
$resolvedSandbox = [IO.Path]::GetFullPath($sandbox)
if (-not $resolvedSandbox.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use a test path outside the system temporary directory: $resolvedSandbox"
}
$codexSandbox = Join-Path $resolvedSandbox 'codex'
$claudeSandbox = Join-Path $resolvedSandbox 'claude'

try {
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'verify.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Repository verification test failed.' }
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\hooks\codex\managed-jobs\tests\CodexManagedJobHooks.Tests.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Codex managed-job hook lifecycle test failed.' }
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\hooks\claude\managed-jobs\tests\ClaudeManagedJobHooks.Tests.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Claude managed-job hook lifecycle test failed.' }

    $null = New-Item -ItemType Directory -Path $codexSandbox -Force
    $lookalikeStopCommand = 'pwsh -NoProfile -ExecutionPolicy Bypass -File "' +
        (Join-Path $codexSandbox 'hooks\managed-jobs\ManagedJob.StopHook.ps1') +
        '" -UnrelatedMode'
    $legacyPreToolCommand = 'pwsh -NoProfile -ExecutionPolicy Bypass -File "' +
        (Join-Path $codexSandbox 'skills\managed-jobs\scripts\ManagedJob.PreToolUseHook.ps1') +
        '"'
    [ordered]@{
        hooks = [ordered]@{
            PreToolUse = @(
                [ordered]@{
                    matcher = '^Bash$'
                    hooks = @(
                        [ordered]@{
                            type = 'command'
                            command = $legacyPreToolCommand
                            commandWindows = $legacyPreToolCommand
                            timeout = 10
                            statusMessage = 'Checking long-running process ownership'
                        }
                    )
                }
            )
            UserPromptSubmit = @(
                [ordered]@{
                    hooks = @(
                        [ordered]@{
                            type = 'command'
                            command = 'unrelated-hook'
                            commandWindows = 'unrelated-hook'
                            timeout = 5
                        },
                        [ordered]@{
                            type = 'command'
                            command = $lookalikeStopCommand
                            commandWindows = $lookalikeStopCommand
                            timeout = 7
                        }
                    )
                }
            )
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $codexSandbox 'hooks.json') -Encoding utf8

    $null = New-Item -ItemType Directory -Path $claudeSandbox -Force
    $claudeSettingsPath = Join-Path $claudeSandbox 'settings.json'
    $claudeLegacyPreToolCommand = 'pwsh -NoProfile -ExecutionPolicy Bypass -File "' +
        (Join-Path $claudeSandbox 'skills\managed-jobs\scripts\ManagedJob.PreToolUseHook.ps1') +
        '"'
    [ordered]@{
        model = 'opus'
        permissions = [ordered]@{ allow = @('Read') }
        hooks = [ordered]@{
            PreToolUse = @(
                [ordered]@{
                    matcher = '^Bash$'
                    hooks = @(
                        [ordered]@{
                            type = 'command'
                            command = $claudeLegacyPreToolCommand
                            timeout = 10
                        }
                    )
                }
            )
            UserPromptSubmit = @(
                [ordered]@{
                    hooks = @(
                        [ordered]@{
                            type = 'command'
                            command = 'claude-unrelated-hook'
                            timeout = 5
                        }
                    )
                }
            )
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $claudeSettingsPath -Encoding utf8

    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'install.ps1') `
        -Target All `
        -CodexHome $codexSandbox `
        -ClaudeHome $claudeSandbox `
        -AllowDirty `
        -AllowNonMain
    if ($LASTEXITCODE -ne 0) { throw 'Sandbox installation test failed.' }

    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'status.ps1') `
        -Target All `
        -CodexHome $codexSandbox `
        -ClaudeHome $claudeSandbox `
        -SummaryOnly
    if ($LASTEXITCODE -ne 0) { throw 'Installed sandboxes should be in sync.' }

    $codexHooksPath = Join-Path $codexSandbox 'hooks.json'
    $codexHooks = Get-Content -LiteralPath $codexHooksPath -Raw | ConvertFrom-Json
    if (-not $codexHooks.hooks.UserPromptSubmit -or
        [string]$codexHooks.hooks.UserPromptSubmit[0].hooks[0].command -ne 'unrelated-hook') {
        throw 'Codex hook installation must preserve unrelated hook entries.'
    }
    if (@($codexHooks.hooks.UserPromptSubmit[0].hooks).command -notcontains $lookalikeStopCommand) {
        throw 'Codex hook installation must not claim a different command that merely mentions a managed script path.'
    }
    foreach ($event in @('PreToolUse', 'Stop', 'SessionEnd')) {
        if (-not $codexHooks.hooks.PSObject.Properties[$event]) {
            throw "Codex hook installation did not register $event."
        }
    }
    $preToolHandlers = @($codexHooks.hooks.PreToolUse | ForEach-Object { $_.hooks })
    if ($preToolHandlers.Count -ne 1 -or
        [string]$preToolHandlers[0].command -notmatch 'ManagedHookId "managed-jobs-pre-tool-use"') {
        throw 'Codex hook installation did not replace the exact legacy PreToolUse command with one marked managed definition.'
    }
    foreach ($script in @('ManagedJob.StopHook.ps1', 'ManagedJob.SessionEndHook.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $codexSandbox "hooks\managed-jobs\$script") -PathType Leaf)) {
            throw "Codex hook installation did not copy $script."
        }
    }
    if (Test-Path -LiteralPath (Join-Path $claudeSandbox 'hooks.json')) {
        throw 'Claude hook installation must register in settings.json, not a Codex-style hooks.json.'
    }

    $claudeSettings = Get-Content -LiteralPath $claudeSettingsPath -Raw | ConvertFrom-Json
    if ([string]$claudeSettings.model -ne 'opus' -or
        @($claudeSettings.permissions.allow) -notcontains 'Read') {
        throw 'Claude hook installation must preserve unrelated settings keys.'
    }
    if (-not $claudeSettings.hooks.UserPromptSubmit -or
        [string]$claudeSettings.hooks.UserPromptSubmit[0].hooks[0].command -ne 'claude-unrelated-hook') {
        throw 'Claude hook installation must preserve unrelated hook entries.'
    }
    foreach ($event in @('PreToolUse', 'Stop', 'SessionEnd')) {
        if (-not $claudeSettings.hooks.PSObject.Properties[$event]) {
            throw "Claude hook installation did not register $event."
        }
    }
    $claudePreToolHandlers = @($claudeSettings.hooks.PreToolUse | ForEach-Object { $_.hooks })
    if ($claudePreToolHandlers.Count -ne 1 -or
        [string]$claudePreToolHandlers[0].command -notmatch 'ManagedHookId "managed-jobs-pre-tool-use"') {
        throw 'Claude hook installation did not replace the exact legacy PreToolUse command with one marked managed definition.'
    }
    foreach ($event in @('PreToolUse', 'Stop', 'SessionEnd')) {
        foreach ($handler in @($claudeSettings.hooks.$event | ForEach-Object { $_.hooks })) {
            if ($handler.PSObject.Properties['commandWindows'] -or $handler.PSObject.Properties['statusMessage']) {
                throw 'Claude hook handlers must carry only fields that Claude Code settings accept.'
            }
        }
    }
    foreach ($script in @('ManagedJob.StopHook.ps1', 'ManagedJob.SessionEndHook.ps1')) {
        $installedHookScript = Join-Path $claudeSandbox "hooks\managed-jobs\$script"
        if (-not (Test-Path -LiteralPath $installedHookScript -PathType Leaf)) {
            throw "Claude hook installation did not copy $script."
        }
        $claudeHookSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\hooks\claude\managed-jobs\$script") -Raw
        if ((Get-Content -LiteralPath $installedHookScript -Raw) -cne $claudeHookSource) {
            throw "Claude installed $script must come from hooks/claude, not the Codex variant."
        }
    }

    $sessionEndDefinitionBeforeRepair = $codexHooks.hooks.SessionEnd | ConvertTo-Json -Depth 10 -Compress
    $codexHooks.hooks.Stop[0].hooks[0].timeout = 1
    $codexHooks | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $codexHooksPath -Encoding utf8
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'status.ps1') `
        -Target Codex `
        -CodexHome $codexSandbox `
        -SummaryOnly
    if ($LASTEXITCODE -ne 1) { throw 'Codex status should detect managed hook drift.' }

    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'install.ps1') `
        -Target Codex `
        -CodexHome $codexSandbox `
        -AllowDirty `
        -AllowNonMain
    if ($LASTEXITCODE -ne 0) { throw 'Codex hook repair installation failed.' }
    $repairedHooks = Get-Content -LiteralPath $codexHooksPath -Raw | ConvertFrom-Json
    if ([int]$repairedHooks.hooks.Stop[0].hooks[0].timeout -ne 15) {
        throw 'Codex hook repair did not restore the reviewed timeout.'
    }
    if (($repairedHooks.hooks.SessionEnd | ConvertTo-Json -Depth 10 -Compress) -cne $sessionEndDefinitionBeforeRepair) {
        throw 'Repairing one managed hook must not rewrite an in-sync managed hook definition.'
    }
    if ([string]$repairedHooks.hooks.UserPromptSubmit[0].hooks[0].command -ne 'unrelated-hook') {
        throw 'Codex hook repair must preserve unrelated hook entries.'
    }
    if (@($repairedHooks.hooks.UserPromptSubmit[0].hooks).command -notcontains $lookalikeStopCommand) {
        throw 'Codex hook repair must preserve lookalike commands that it does not own.'
    }

    $misplacedStopGroup = $repairedHooks.hooks.Stop[0]
    $legacyManagedStopCommand = 'pwsh -NoProfile -ExecutionPolicy Bypass -File "' +
        (Join-Path $codexSandbox 'hooks\legacy\ManagedJob.StopHook.ps1') +
        '" -ManagedHookId "managed-jobs-stop"'
    $misplacedStopGroup.hooks[0].command = $legacyManagedStopCommand
    $misplacedStopGroup.hooks[0].commandWindows = $legacyManagedStopCommand
    $repairedHooks.hooks.PSObject.Properties.Remove('Stop')
    $repairedHooks.hooks.SessionEnd = @($repairedHooks.hooks.SessionEnd) + @($misplacedStopGroup)
    $repairedHooks | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $codexHooksPath -Encoding utf8
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'status.ps1') `
        -Target Codex `
        -CodexHome $codexSandbox `
        -SummaryOnly
    if ($LASTEXITCODE -ne 1) { throw 'Codex status should detect a managed handler registered under the wrong event.' }

    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'install.ps1') `
        -Target Codex `
        -CodexHome $codexSandbox `
        -AllowDirty `
        -AllowNonMain
    if ($LASTEXITCODE -ne 0) { throw 'Codex misplaced-hook repair installation failed.' }
    $relocatedHooks = Get-Content -LiteralPath $codexHooksPath -Raw | ConvertFrom-Json
    $stopScriptName = 'ManagedJob.StopHook.ps1'
    $wrongEventCommands = @($relocatedHooks.hooks.SessionEnd | ForEach-Object { $_.hooks } |
        ForEach-Object { @($_.command, $_.commandWindows) })
    $repairedStopCommand = [string]$relocatedHooks.hooks.Stop[0].hooks[0].command
    if (-not $relocatedHooks.hooks.Stop -or
        $wrongEventCommands -match 'ManagedHookId "managed-jobs-stop"' -or
        $repairedStopCommand -notmatch 'ManagedHookId "managed-jobs-stop"' -or
        $repairedStopCommand -notmatch [regex]::Escape($stopScriptName)) {
        throw 'Codex hook repair did not replace the moved legacy managed command with the current Stop handler.'
    }

    $claudeSettings = Get-Content -LiteralPath $claudeSettingsPath -Raw | ConvertFrom-Json
    $claudeSettings.hooks.Stop[0].hooks[0].timeout = 1
    $claudeSettings.hooks.SessionEnd[0].hooks[0] |
        Add-Member -NotePropertyName async -NotePropertyValue $true
    $claudeSettings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $claudeSettingsPath -Encoding utf8
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'status.ps1') `
        -Target Claude `
        -ClaudeHome $claudeSandbox `
        -SummaryOnly
    if ($LASTEXITCODE -ne 1) { throw 'Claude status should detect managed hook drift.' }

    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'install.ps1') `
        -Target Claude `
        -ClaudeHome $claudeSandbox `
        -AllowDirty `
        -AllowNonMain
    if ($LASTEXITCODE -ne 0) { throw 'Claude hook repair installation failed.' }
    $repairedClaudeSettings = Get-Content -LiteralPath $claudeSettingsPath -Raw | ConvertFrom-Json
    if ([int]$repairedClaudeSettings.hooks.Stop[0].hooks[0].timeout -ne 15) {
        throw 'Claude hook repair did not restore the reviewed timeout.'
    }
    if ($repairedClaudeSettings.hooks.SessionEnd[0].hooks[0].PSObject.Properties['async']) {
        throw 'Claude hook repair must strip execution-changing extra fields from a managed handler.'
    }
    if ([string]$repairedClaudeSettings.model -ne 'opus' -or
        [string]$repairedClaudeSettings.hooks.UserPromptSubmit[0].hooks[0].command -ne 'claude-unrelated-hook') {
        throw 'Claude hook repair must preserve unrelated settings and hook entries.'
    }

    Add-Content -LiteralPath (Join-Path $claudeSandbox 'CLAUDE.md') -Value "`n# deliberate test drift"
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'status.ps1') `
        -Target Claude `
        -ClaudeHome $claudeSandbox `
        -SummaryOnly
    if ($LASTEXITCODE -ne 1) { throw 'Claude status should return exit code 1 after deliberate drift.' }

    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'status.ps1') `
        -Target Codex `
        -CodexHome $codexSandbox `
        -SummaryOnly
    if ($LASTEXITCODE -ne 0) { throw 'Claude drift should not affect Codex status.' }

    Write-Host 'Deployment smoke test: OK'
} finally {
    if (Test-Path -LiteralPath $resolvedSandbox) {
        $confirmed = [IO.Path]::GetFullPath($resolvedSandbox)
        if (-not $confirmed.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a path outside the system temporary directory: $confirmed"
        }
        Remove-Item -LiteralPath $confirmed -Recurse -Force
    }
}

exit 0
