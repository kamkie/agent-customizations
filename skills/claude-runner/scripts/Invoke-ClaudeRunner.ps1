[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Prompt,

    [string]$PromptFile,
    [int]$ReviewPr,

    [ValidateSet("fable", "haiku", "opus", "sonnet")]
    [string]$ModelAlias = "fable",

    [ValidatePattern("^claude-[A-Za-z0-9][A-Za-z0-9._-]*$")]
    [string]$ExactModel,

    [ValidateSet("low", "medium", "high", "xhigh", "max")]
    [string]$Effort = "medium",

    [ValidateSet("acceptEdits", "auto", "default", "dontAsk", "plan")]
    [string]$PermissionMode = "default",
    [switch]$BypassPermissions,
    [string[]]$AllowedTools = @(),

    [string]$SessionId,
    [string]$Resume,
    [switch]$ContinueLatest,
    [int]$FromPr,
    [string]$Name,

    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$ClaudeConfigDirectory,
    [string]$LogDir,
    [string]$LogPath,
    [switch]$AppendLog,

    [decimal]$MaxBudgetUsd,
    [int]$MaxTurns,
    [switch]$Bare,
    [switch]$NoVerbose,
    [switch]$ShowJson,
    [switch]$ShowEvents,
    [switch]$DryRun,
    [switch]$SelfTest,

    [string[]]$ClaudeArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$forbiddenArgs = @("--bg", "--background", "--fork-session", "--no-session-persistence")
$typedArgs = @(
    "-p", "--print", "--model", "--effort", "--permission-mode",
    "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
    "--allowedTools", "--allowed-tools",
    "--session-id", "--resume", "--continue", "--from-pr", "--name",
    "--max-budget-usd", "--max-turns", "--output-format",
    "--include-partial-messages", "--verbose", "--bare"
)
foreach ($arg in $ClaudeArgs) {
    $argName = if ($arg -match "^(--?[^=]+)=") { $Matches[1] } else { $arg }
    if ($forbiddenArgs -contains $argName) {
        throw "Do not pass $argName through claude-runner. It breaks attached resumable execution."
    }
    if ($typedArgs -contains $argName) {
        throw "Use the typed claude-runner parameter for $argName instead of -ClaudeArgs."
    }
}

if ($BypassPermissions -and $PSBoundParameters.ContainsKey("PermissionMode")) {
    throw "Use either -PermissionMode or -BypassPermissions, not both."
}

if ($BypassPermissions -and $AllowedTools.Count -gt 0) {
    throw "Do not combine -AllowedTools with -BypassPermissions. Allowed tools do not constrain bypass mode."
}

if ($ReviewPr -gt 0 -and $BypassPermissions) {
    throw "Do not combine -ReviewPr with -BypassPermissions. PR reviews use the read-only review profile."
}

if ($ReviewPr -gt 0 -and $AllowedTools.Count -gt 0) {
    throw "Do not combine -ReviewPr with -AllowedTools. PR reviews use the fixed read-only review profile."
}

if ($ReviewPr -gt 0 -and $PSBoundParameters.ContainsKey("PermissionMode") -and $PermissionMode -ne "dontAsk") {
    throw "PR reviews require -PermissionMode dontAsk. Omit -PermissionMode to use the review profile automatically."
}

if (($ReviewPr -gt 0 -or $FromPr -gt 0) -and $Bare) {
    throw "Do not combine -Bare with -ReviewPr or -FromPr. PR-linked reviews require repository instructions and settings."
}

if ($ReviewPr -gt 0 -and $FromPr -gt 0 -and $ReviewPr -ne $FromPr) {
    throw "-FromPr must match -ReviewPr when both are provided."
}

if (-not [string]::IsNullOrWhiteSpace($ExactModel) -and $PSBoundParameters.ContainsKey("ModelAlias")) {
    throw "Use either -ModelAlias or -ExactModel, not both."
}

$selectedModel = if ([string]::IsNullOrWhiteSpace($ExactModel)) { $ModelAlias } else { $ExactModel }
$reviewProfileEnabled = $ReviewPr -gt 0
$selectedPermissionMode = if ($reviewProfileEnabled) { "dontAsk" } else { $PermissionMode }
$displayPermissionMode = if ($BypassPermissions) {
    "bypassPermissions"
} elseif ($reviewProfileEnabled) {
    "review-read-only (dontAsk + pre-approved tools)"
} else {
    $PermissionMode
}

$reviewAllowedTools = @(
    "Read", "Glob", "Grep",
    "Bash(gh pr view *)", "Bash(gh pr diff *)",
    "Bash(git diff *)", "Bash(git log *)", "Bash(git rev-parse *)", "Bash(git show *)", "Bash(git status *)",
    "PowerShell(gh pr view *)", "PowerShell(gh pr diff *)",
    "PowerShell(git diff *)", "PowerShell(git log *)", "PowerShell(git rev-parse *)", "PowerShell(git show *)", "PowerShell(git status *)"
)
$effectiveAllowedTools = @()
if ($reviewProfileEnabled) {
    $effectiveAllowedTools += $reviewAllowedTools
}
$effectiveAllowedTools += $AllowedTools

function Format-Arg {
    param([string]$Value)

    if ($Value -match "^[A-Za-z0-9_./:=@\\-]+$") {
        return $Value
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function Format-CommandArgsForDisplay {
    param([string[]]$CommandArgs)

    $displayArgs = New-Object System.Collections.Generic.List[string]
    $redactNext = $false
    foreach ($arg in $CommandArgs) {
        if ($redactNext) {
            [void]$displayArgs.Add("<prompt:$($arg.Length) chars>")
            $redactNext = $false
            continue
        }

        [void]$displayArgs.Add($arg)
        if ($arg -eq "-p" -or $arg -eq "--print") {
            $redactNext = $true
        }
    }

    return (($displayArgs | ForEach-Object { Format-Arg $_ }) -join " ")
}

function Get-DefaultClaudeConfigDirectory {
    param([string]$BaseDirectory)

    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) {
        if ([System.IO.Path]::IsPathRooted($env:CLAUDE_CONFIG_DIR)) {
            return $env:CLAUDE_CONFIG_DIR
        }
        return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $env:CLAUDE_CONFIG_DIR))
    }

    return Join-Path $HOME ".claude"
}

function Write-FullTextDelta {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return
    }

    if ($script:LastFullText -and $Text.StartsWith($script:LastFullText)) {
        $delta = $Text.Substring($script:LastFullText.Length)
    } else {
        if ($script:RenderedText) {
            Write-Host ""
        }
        $delta = $Text
    }

    if ($delta.Length -gt 0) {
        Write-Host -NoNewline $delta
        $script:RenderedText = $true
        $script:NeedsNewline = -not ($delta.EndsWith("`n") -or $delta.EndsWith("`r"))
    }

    $script:LastFullText = $Text
}

function Get-ObjectPropertyNames {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value.PSObject.Properties.Name)
}

function Get-ContentText {
    param($Content)

    if ($null -eq $Content) {
        return ""
    }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Content)) {
        $props = Get-ObjectPropertyNames $item
        if (($props -contains "type") -and $item.type -ne "text") {
            continue
        }
        if ($props -contains "text") {
            [void]$parts.Add([string]$item.text)
        }
    }

    return ($parts -join "")
}

function Write-ClaudeStreamLine {
    param([string]$Line)

    if ($ShowJson) {
        Write-Host $Line
    }

    try {
        $event = $Line | ConvertFrom-Json -Depth 100
    } catch {
        if (-not $ShowJson) {
            Write-Host $Line
        }
        return
    }

    $props = Get-ObjectPropertyNames $event
    if (-not ($props -contains "type")) {
        if ($ShowEvents) {
            Write-Host "[claude-runner] JSON event without type"
        }
        return
    }

    switch ($event.type) {
        "stream_event" {
            if (-not (($props -contains "event") -and $event.event)) {
                return
            }

            $inner = $event.event
            $innerProps = Get-ObjectPropertyNames $inner
            if ($innerProps -contains "type") {
                switch ($inner.type) {
                    "content_block_delta" {
                        if (($innerProps -contains "delta") -and $inner.delta) {
                            $deltaProps = Get-ObjectPropertyNames $inner.delta
                            if ($deltaProps -contains "text") {
                                $text = [string]$inner.delta.text
                                Write-Host -NoNewline $text
                                $script:LastFullText += $text
                                $script:RenderedText = $true
                                $script:NeedsNewline = -not ($text.EndsWith("`n") -or $text.EndsWith("`r"))
                            }
                        }
                    }
                    "message_start" {
                        if (($props -contains "session_id") -and -not [string]::IsNullOrWhiteSpace([string]$event.session_id)) {
                            Write-Host ("[claude-runner] stream session: {0}" -f $event.session_id)
                        } elseif ($ShowEvents) {
                            Write-Host "[claude-runner] message_start"
                        }
                    }
                    default {
                        if ($ShowEvents) {
                            Write-Host ("[claude-runner] stream event: {0}" -f $inner.type)
                        }
                    }
                }
            }
        }
        "content_block_delta" {
            if (($props -contains "delta") -and $event.delta) {
                $deltaProps = Get-ObjectPropertyNames $event.delta
                if ($deltaProps -contains "text") {
                    $text = [string]$event.delta.text
                    Write-Host -NoNewline $text
                    $script:LastFullText += $text
                    $script:RenderedText = $true
                    $script:NeedsNewline = -not ($text.EndsWith("`n") -or $text.EndsWith("`r"))
                } elseif (($deltaProps -contains "thinking") -and $ShowEvents) {
                    Write-Host "[claude-runner] thinking chunk"
                }
            }
        }
        "assistant" {
            if (($props -contains "message") -and $event.message) {
                $messageProps = Get-ObjectPropertyNames $event.message
                if ($messageProps -contains "content") {
                    Write-FullTextDelta (Get-ContentText $event.message.content)
                }
            }
        }
        "system" {
            $subtype = if ($props -contains "subtype") { [string]$event.subtype } else { "" }
            switch ($subtype) {
                "init" {
                    if ($props -contains "session_id") {
                        Write-Host ("[claude-runner] stream session: {0}" -f $event.session_id)
                    }
                    if ($ShowEvents -and ($props -contains "model")) {
                        Write-Host ("[claude-runner] model: {0}" -f $event.model)
                    }
                }
                "api_retry" {
                    if ($script:NeedsNewline) {
                        Write-Host ""
                        $script:NeedsNewline = $false
                    }
                    $attempt = if ($props -contains "attempt") { $event.attempt } else { "?" }
                    $maxRetries = if ($props -contains "max_retries") { $event.max_retries } else { "?" }
                    $delay = if ($props -contains "retry_delay_ms") { $event.retry_delay_ms } else { "?" }
                    $errorKind = if ($props -contains "error") { $event.error } else { "unknown" }
                    Write-Host ("[claude-runner] retry {0}/{1} in {2} ms: {3}" -f $attempt, $maxRetries, $delay, $errorKind)
                }
                default {
                    if ($ShowEvents) {
                        Write-Host ("[claude-runner] system event: {0}" -f $subtype)
                    }
                }
            }
        }
        "result" {
            if ($script:NeedsNewline) {
                Write-Host ""
                $script:NeedsNewline = $false
            }
            if (($props -contains "session_id") -and -not [string]::IsNullOrWhiteSpace([string]$event.session_id)) {
                Write-Host ("[claude-runner] result session: {0}" -f $event.session_id)
            }
            if (($props -contains "result") -and -not [string]::IsNullOrEmpty([string]$event.result) -and -not $script:RenderedText) {
                Write-Host ([string]$event.result)
            }
            if (($props -contains "total_cost_usd") -and $null -ne $event.total_cost_usd) {
                Write-Host ("[claude-runner] cost usd: {0}" -f $event.total_cost_usd)
            }
        }
        "error" {
            if ($script:NeedsNewline) {
                Write-Host ""
                $script:NeedsNewline = $false
            }
            Write-Host "[claude-runner] error event:" -ForegroundColor Red
            Write-Host $Line -ForegroundColor Red
        }
        default {
            if ($ShowEvents) {
                Write-Host ("[claude-runner] event: {0}" -f $event.type)
            }
        }
    }
}

function Resolve-RunnerPath {
    param(
        [string]$BaseDirectory,
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

if ($SelfTest) {
    $script:LastFullText = ""
    $script:RenderedText = $false
    $script:NeedsNewline = $false

    @(
        '{"type":"system","subtype":"init"}',
        '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"stream "}},"session_id":"00000000-0000-0000-0000-000000000000"}',
        '{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello "}}',
        '{"type":"content_block_delta","delta":{"type":"text_delta","text":"from claude-runner"}}',
        '{"type":"assistant","message":{"content":[null,"scalar",{"type":"text","text":" safe"}]}}',
        '{"type":"result","total_cost_usd":0}'
    ) | ForEach-Object { Write-ClaudeStreamLine $_ }

    if ($script:NeedsNewline) {
        Write-Host ""
    }
    exit 0
}

$resolvedWorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
if (-not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)) {
    throw "Working directory does not exist: $resolvedWorkingDirectory"
}

if ($ReviewPr -gt 0) {
    if (-not [string]::IsNullOrWhiteSpace($Prompt) -or -not [string]::IsNullOrWhiteSpace($PromptFile)) {
        throw "Use either -ReviewPr, -Prompt, or -PromptFile, not more than one."
    }
    $PromptText = "/review $ReviewPr"
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = "review-$ReviewPr"
    }
} elseif (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
    if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
        throw "Use either -Prompt or -PromptFile, not both."
    }
    $resolvedPromptFile = Resolve-RunnerPath $resolvedWorkingDirectory $PromptFile
    if (-not (Test-Path -LiteralPath $resolvedPromptFile -PathType Leaf)) {
        throw "Prompt file does not exist: $resolvedPromptFile"
    }
    $PromptText = Get-Content -Raw -LiteralPath $resolvedPromptFile
} elseif (-not [string]::IsNullOrWhiteSpace($Prompt)) {
    $PromptText = $Prompt
} else {
    throw "Provide -Prompt, -PromptFile, or -ReviewPr, or use -SelfTest."
}

$resumeModes = 0
if (-not [string]::IsNullOrWhiteSpace($Resume)) { $resumeModes++ }
if ($ContinueLatest) { $resumeModes++ }
if ($FromPr -gt 0) { $resumeModes++ }
if ($resumeModes -gt 1) {
    throw "Use only one resume mode: -Resume, -ContinueLatest, or -FromPr."
}
if ($resumeModes -gt 0 -and -not [string]::IsNullOrWhiteSpace($SessionId)) {
    throw "Do not combine -SessionId with resume modes. Use -Resume <session-id> to continue that session."
}

$cmdArgs = @()
if ($Bare) {
    $cmdArgs += "--bare"
}
$cmdArgs += @("--model", $selectedModel, "--effort", $Effort)
if ($BypassPermissions) {
    $cmdArgs += "--dangerously-skip-permissions"
} else {
    $cmdArgs += @("--permission-mode", $selectedPermissionMode)
}
if (-not [string]::IsNullOrWhiteSpace($Name)) {
    $cmdArgs += @("--name", $Name)
}
if ($PSBoundParameters.ContainsKey("MaxBudgetUsd")) {
    $cmdArgs += @("--max-budget-usd", $MaxBudgetUsd.ToString([Globalization.CultureInfo]::InvariantCulture))
}
if ($PSBoundParameters.ContainsKey("MaxTurns")) {
    $cmdArgs += @("--max-turns", [string]$MaxTurns)
}

if (-not [string]::IsNullOrWhiteSpace($Resume)) {
    $effectiveSession = $Resume
    $mode = "resume"
    $cmdArgs += @("--resume", $Resume)
} elseif ($ContinueLatest) {
    $effectiveSession = "continue-latest"
    $mode = "continue"
    $cmdArgs += "--continue"
} elseif ($FromPr -gt 0) {
    $effectiveSession = "from-pr-$FromPr"
    $mode = "from-pr"
    $cmdArgs += @("--from-pr", [string]$FromPr)
} else {
    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        $SessionId = [guid]::NewGuid().ToString()
    }
    $effectiveSession = $SessionId
    $mode = "new"
    $cmdArgs += @("--session-id", $SessionId)
}

$cmdArgs += @(
    "-p", $PromptText,
    "--output-format", "stream-json",
    "--include-partial-messages"
)
if (-not $NoVerbose) {
    $cmdArgs += "--verbose"
}
$displayArgs = @($cmdArgs)
if ($effectiveAllowedTools.Count -gt 0) {
    $cmdArgs += @("--allowedTools", ($effectiveAllowedTools -join ","))
}
$cmdArgs += $ClaudeArgs

$resolvedClaudeConfigDirectory = if ([string]::IsNullOrWhiteSpace($ClaudeConfigDirectory)) {
    Get-DefaultClaudeConfigDirectory $resolvedWorkingDirectory
} else {
    Resolve-RunnerPath $resolvedWorkingDirectory $ClaudeConfigDirectory
}
$resolvedLogDir = if ([string]::IsNullOrWhiteSpace($LogDir)) {
    Join-Path $resolvedClaudeConfigDirectory "logs\claude-runner"
} else {
    Resolve-RunnerPath $resolvedWorkingDirectory $LogDir
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $safeSession = ($effectiveSession -replace "[^A-Za-z0-9_.-]", "-")
    $prefix = if ($ReviewPr -gt 0) { "claude-review-$ReviewPr" } else { "claude" }
    $LogPath = Join-Path $resolvedLogDir "$prefix-$safeSession.jsonl"
} else {
    $LogPath = Resolve-RunnerPath $resolvedWorkingDirectory $LogPath
}

Write-Host ("[claude-runner] cwd: {0}" -f $resolvedWorkingDirectory)
Write-Host ("[claude-runner] mode: {0}" -f $mode)
Write-Host ("[claude-runner] session: {0}" -f $effectiveSession)
Write-Host ("[claude-runner] model: {0}" -f $selectedModel)
Write-Host ("[claude-runner] effort: {0}" -f $Effort)
Write-Host ("[claude-runner] permissions: {0}{1}" -f $displayPermissionMode, $(if ($BypassPermissions) { " (EXPLICIT BYPASS)" } else { "" }))
Write-Host ("[claude-runner] native sessions: {0} (managed by Claude Code)" -f (Join-Path $resolvedClaudeConfigDirectory "projects"))
Write-Host ("[claude-runner] diagnostic log: {0}" -f $LogPath)
$commandSummary = Format-CommandArgsForDisplay $displayArgs
if ($effectiveAllowedTools.Count -gt 0) {
    $commandSummary += " <allowed-tools:$($effectiveAllowedTools.Count) rules redacted>"
}
if ($ClaudeArgs.Count -gt 0) {
    $commandSummary += " <passthrough:$($ClaudeArgs.Count) args redacted>"
}
Write-Host ("[claude-runner] command: claude {0}" -f $commandSummary)

if ($DryRun) {
    exit 0
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null

$script:LastFullText = ""
$script:RenderedText = $false
$script:NeedsNewline = $false

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$shouldAppendLog = [bool]$AppendLog -or (Test-Path -LiteralPath $LogPath)
Write-Host ("[claude-runner] log mode: {0}" -f ($(if ($shouldAppendLog) { "append" } else { "create" })))
$writer = [System.IO.StreamWriter]::new($LogPath, $shouldAppendLog, $utf8NoBom)
$hadClaudeConfigDirectory = Test-Path Env:CLAUDE_CONFIG_DIR
$previousClaudeConfigDirectory = $env:CLAUDE_CONFIG_DIR

try {
    $env:CLAUDE_CONFIG_DIR = $resolvedClaudeConfigDirectory
    Push-Location $resolvedWorkingDirectory
    try {
        & claude @cmdArgs 2>&1 | ForEach-Object {
            $line = [string]$_
            $writer.WriteLine($line)
            $writer.Flush()
            Write-ClaudeStreamLine $line
        }
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
} finally {
    $writer.Dispose()
    if ($hadClaudeConfigDirectory) {
        $env:CLAUDE_CONFIG_DIR = $previousClaudeConfigDirectory
    } else {
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    }
}

if ($script:NeedsNewline) {
    Write-Host ""
}

Write-Host ("[claude-runner] exit: {0}" -f $exitCode)
exit $exitCode
