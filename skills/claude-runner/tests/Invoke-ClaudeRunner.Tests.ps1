[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "..\scripts\Invoke-ClaudeRunner.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-runner-tests-" + [guid]::NewGuid())
$fakeBin = Join-Path $testRoot "bin"
$target = Join-Path $testRoot "target"
$runtime = Join-Path $testRoot "runtime"
$argsLog = Join-Path $testRoot "claude-args.jsonl"
$oldPath = $env:PATH

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-RunnerProcess {
    param([string[]]$Arguments)

    $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $runner @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join "`n")
    }
}

try {
    New-Item -ItemType Directory -Force -Path $fakeBin, $target | Out-Null
    @'
$args | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:FAKE_CLAUDE_ARGS_LOG
Write-Output $env:FAKE_CLAUDE_EVENT
exit [int]$env:FAKE_CLAUDE_EXIT
'@ | Set-Content -LiteralPath (Join-Path $fakeBin "claude.ps1") -Encoding utf8NoBOM

    $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$oldPath"
    $env:FAKE_CLAUDE_ARGS_LOG = $argsLog
    $env:FAKE_CLAUDE_EVENT = '{"type":"result","session_id":"11111111-1111-4111-8111-111111111111","result":"mock complete","total_cost_usd":0}'
    $env:FAKE_CLAUDE_EXIT = "0"

    $selfTarget = Join-Path $testRoot "self-target-must-not-exist"
    $selfRuntime = Join-Path $testRoot "self-runtime-must-not-exist"
    $self = Invoke-RunnerProcess @("-SelfTest", "-WorkingDirectory", $selfTarget, "-RuntimeRoot", $selfRuntime)
    Assert-True ($self.ExitCode -eq 0) "SelfTest failed: $($self.Output)"
    Assert-True (-not (Test-Path -LiteralPath $selfTarget)) "SelfTest created its working directory."
    Assert-True (-not (Test-Path -LiteralPath $selfRuntime)) "SelfTest created its runtime directory."

    $dryRuntime = Join-Path $testRoot "dry-runtime-must-not-exist"
    $dryLog = Join-Path $dryRuntime "nested\dry.jsonl"
    $secretPrompt = "PROMPT-MUST-NOT-APPEAR-7d641d"
    $secretArgument = "--allowedTools=ARGUMENT-MUST-NOT-APPEAR-5af09e"
    $dry = Invoke-RunnerProcess @(
        "-Prompt", $secretPrompt,
        "-WorkingDirectory", $target,
        "-RuntimeRoot", $dryRuntime,
        "-LogPath", $dryLog,
        "-ExactModel", "claude-opus-4-6",
        "-Effort", "medium",
        "-ClaudeArgs", $secretArgument,
        "-DryRun"
    )
    Assert-True ($dry.ExitCode -eq 0) "DryRun failed: $($dry.Output)"
    Assert-True (-not (Test-Path -LiteralPath $dryRuntime)) "DryRun created a runtime directory."
    Assert-True (-not ($dry.Output.Contains($secretPrompt))) "DryRun leaked the prompt in its summary."
    Assert-True (-not ($dry.Output.Contains($secretArgument))) "DryRun leaked a passthrough argument in its summary."
    Assert-True ($dry.Output.Contains("permissions: default")) "DryRun did not report normal permissions."
    Assert-True ($dry.Output.Contains("--effort medium")) "DryRun did not bind typed medium effort."
    Assert-True ($dry.Output.Contains("--model claude-opus-4-6")) "DryRun did not select the exact model."

    $bypass = Invoke-RunnerProcess @(
        "-Prompt", "safe",
        "-WorkingDirectory", $target,
        "-RuntimeRoot", (Join-Path $testRoot "bypass-runtime-must-not-exist"),
        "-BypassPermissions",
        "-DryRun"
    )
    Assert-True ($bypass.ExitCode -eq 0) "Explicit bypass DryRun failed: $($bypass.Output)"
    Assert-True ($bypass.Output.Contains("permissions: bypassPermissions (EXPLICIT BYPASS)")) "Bypass was not conspicuous in output."
    Assert-True ($bypass.Output.Contains("--dangerously-skip-permissions")) "Bypass flag was not explicit in the invocation."

    $before = @(Get-ChildItem -Force -Recurse -LiteralPath $target | ForEach-Object FullName)
    $session = "11111111-1111-4111-8111-111111111111"
    $run = Invoke-RunnerProcess @(
        "-Prompt", "mock run",
        "-SessionId", $session,
        "-WorkingDirectory", $target,
        "-RuntimeRoot", $runtime,
        "-MaxBudgetUsd", "1.25",
        "-MaxTurns", "4"
    )
    Assert-True ($run.ExitCode -eq 0) "Default mock execution failed: $($run.Output)"
    $after = @(Get-ChildItem -Force -Recurse -LiteralPath $target | ForEach-Object FullName)
    Assert-True (($before -join "`n") -eq ($after -join "`n")) "Default execution mutated the target repository."
    Assert-True ($run.Output.Contains("permissions: default")) "Default execution did not use normal permissions."
    Assert-True (-not $run.Output.Contains("dangerously-skip-permissions")) "Default execution enabled bypass permissions."
    $logPath = Join-Path $runtime "claude-runner\logs\claude-$session.jsonl"
    Assert-True (Test-Path -LiteralPath $logPath -PathType Leaf) "External durable log was not created."
    Assert-True (-not $logPath.StartsWith($target, [StringComparison]::OrdinalIgnoreCase)) "Default log was written inside the target repository."

    $firstArgs = (Get-Content -LiteralPath $argsLog | Select-Object -First 1) | ConvertFrom-Json
    Assert-True ($firstArgs.Contains("--permission-mode") -and $firstArgs.Contains("default")) "Claude did not receive default permission mode."
    Assert-True ($firstArgs.Contains("--effort") -and $firstArgs.Contains("medium")) "Claude did not receive typed medium effort."
    Assert-True ($firstArgs.Contains("--max-budget-usd") -and $firstArgs.Contains("1.25")) "Claude did not receive the budget control."
    Assert-True ($firstArgs.Contains("--max-turns") -and $firstArgs.Contains("4")) "Claude did not receive the turn control."
    Assert-True ($run.Output.Contains("mock complete")) "Claude stream output was not rendered."

    $env:FAKE_CLAUDE_EVENT = '{"type":"system","subtype":"init","session_id":"11111111-1111-4111-8111-111111111111"}'
    $env:FAKE_CLAUDE_EXIT = "130"
    $interrupted = Invoke-RunnerProcess @(
        "-Prompt", "interrupted mock",
        "-SessionId", $session,
        "-WorkingDirectory", $target,
        "-RuntimeRoot", $runtime,
        "-AppendLog"
    )
    Assert-True ($interrupted.ExitCode -eq 130) "Interrupted mock did not preserve the Claude exit code."

    $env:FAKE_CLAUDE_EVENT = '{"type":"result","session_id":"11111111-1111-4111-8111-111111111111","result":"resumed","total_cost_usd":0}'
    $env:FAKE_CLAUDE_EXIT = "0"
    $resumed = Invoke-RunnerProcess @(
        "-Prompt", "resume delta",
        "-Resume", $session,
        "-WorkingDirectory", $target,
        "-RuntimeRoot", $runtime,
        "-AppendLog"
    )
    Assert-True ($resumed.ExitCode -eq 0) "Interrupted-session resume failed: $($resumed.Output)"
    $lastArgs = (Get-Content -LiteralPath $argsLog | Select-Object -Last 1) | ConvertFrom-Json
    Assert-True ($lastArgs.Contains("--resume") -and $lastArgs.Contains($session)) "Resume did not reuse the interrupted session id."
    Assert-True (-not $lastArgs.Contains("--session-id")) "Resume incorrectly created a new session."
    Assert-True ((Get-Content -LiteralPath $logPath).Count -ge 3) "Resume did not append to the durable session log."

    $fromPr = Invoke-RunnerProcess @(
        "-ReviewPr", "17",
        "-FromPr", "17",
        "-WorkingDirectory", $target,
        "-RuntimeRoot", $runtime
    )
    Assert-True ($fromPr.ExitCode -eq 0) "PR-linked recovery failed: $($fromPr.Output)"
    $prArgs = (Get-Content -LiteralPath $argsLog | Select-Object -Last 1) | ConvertFrom-Json
    Assert-True ($prArgs.Contains("--from-pr") -and $prArgs.Contains("17")) "PR-linked recovery did not pass --from-pr 17."

    Write-Host "claude-runner regression tests passed"
} finally {
    $env:PATH = $oldPath
    Remove-Item Env:FAKE_CLAUDE_ARGS_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CLAUDE_EVENT -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_CLAUDE_EXIT -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -Recurse -Force -LiteralPath $testRoot
    }
}
