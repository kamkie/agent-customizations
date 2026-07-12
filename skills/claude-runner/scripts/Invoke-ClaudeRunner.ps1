[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Prompt,

    [string]$PromptFile,
    [int]$ReviewPr,

    [ValidateSet("fable", "opus")]
    [string]$Model = "fable",

    [ValidateSet("acceptEdits", "auto", "bypassPermissions", "default", "plan")]
    [string]$PermissionMode = "bypassPermissions",

    [string]$SessionId,
    [string]$Resume,
    [switch]$ContinueLatest,
    [int]$FromPr,
    [string]$Name,

    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$LogDir = ".logs",
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
foreach ($arg in $ClaudeArgs) {
    if ($forbiddenArgs -contains $arg) {
        throw "Do not pass $arg through claude-runner. It breaks attached resumable execution."
    }
}

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

function Get-ContentText {
    param($Content)

    if ($null -eq $Content) {
        return ""
    }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Content)) {
        $props = $item.PSObject.Properties.Name
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

    $props = $event.PSObject.Properties.Name
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
            $innerProps = $inner.PSObject.Properties.Name
            if ($innerProps -contains "type") {
                switch ($inner.type) {
                    "content_block_delta" {
                        if (($innerProps -contains "delta") -and $inner.delta) {
                            $deltaProps = $inner.delta.PSObject.Properties.Name
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
                        if (($event.PSObject.Properties.Name -contains "session_id") -and -not [string]::IsNullOrWhiteSpace([string]$event.session_id)) {
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
            if (($event.PSObject.Properties.Name -contains "delta") -and $event.delta) {
                $deltaProps = $event.delta.PSObject.Properties.Name
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
                $messageProps = $event.message.PSObject.Properties.Name
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
$cmdArgs += @("--model", $Model, "--permission-mode", $PermissionMode)
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
$cmdArgs += $ClaudeArgs

$resolvedLogDir = Resolve-RunnerPath $resolvedWorkingDirectory $LogDir
New-Item -ItemType Directory -Force -Path $resolvedLogDir | Out-Null

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
Write-Host ("[claude-runner] log: {0}" -f $LogPath)
Write-Host ("[claude-runner] command: claude {0}" -f (Format-CommandArgsForDisplay $cmdArgs))

if ($DryRun) {
    exit 0
}

$script:LastFullText = ""
$script:RenderedText = $false
$script:NeedsNewline = $false

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$shouldAppendLog = [bool]$AppendLog -or (Test-Path -LiteralPath $LogPath)
Write-Host ("[claude-runner] log mode: {0}" -f ($(if ($shouldAppendLog) { "append" } else { "create" })))
$writer = [System.IO.StreamWriter]::new($LogPath, $shouldAppendLog, $utf8NoBom)

try {
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
}

if ($script:NeedsNewline) {
    Write-Host ""
}

Write-Host ("[claude-runner] exit: {0}" -f $exitCode)
exit $exitCode
