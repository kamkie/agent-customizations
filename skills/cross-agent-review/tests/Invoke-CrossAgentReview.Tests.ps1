[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$controller = Join-Path $PSScriptRoot '..\scripts\Invoke-CrossAgentReview.ps1'
$shellController = Join-Path $PSScriptRoot '..\scripts\invoke-cross-agent-review.sh'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('cross-agent-review-tests-' + [guid]::NewGuid())
$target = Join-Path $testRoot 'target'
$origin = Join-Path $testRoot 'origin.git'
$fakeBin = Join-Path $testRoot 'bin'
$fakeCodexHome = Join-Path $testRoot 'codex-home'
$runnerPath = Join-Path $fakeCodexHome 'skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1'
$runnerRecord = Join-Path $testRoot 'runner-record.json'
$focusFile = Join-Path $testRoot 'focus.md'
$oldPath = $env:PATH
$oldCodexHome = $env:CODEX_HOME
$oldRunnerRecord = $env:FAKE_RUNNER_RECORD
$oldPrHead = $env:FAKE_PR_HEAD
$assertions = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:assertions++
}

function Invoke-Git {
    param([Parameter(Mandatory)][string]$WorkingDirectory, [Parameter(Mandatory)][string[]]$Arguments)
    $output = & git -C $WorkingDirectory @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join "`n")" }
    return @($output)
}

function Invoke-Controller {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $startInfo.WorkingDirectory = $target
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $controller) + $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $standardOutput
        Stderr = $standardError
    }
}

try {
    New-Item -ItemType Directory -Force -Path $target, $origin, $fakeBin, (Split-Path -Parent $runnerPath) | Out-Null

    @'
if ($args -contains 'headRefOid') {
    Write-Output $env:FAKE_PR_HEAD
    exit 0
}
if ($args -contains 'number') {
    Write-Output '85'
    exit 0
}
Write-Error "Unexpected fake gh invocation: $($args -join ' ')"
exit 1
'@ | Set-Content -LiteralPath (Join-Path $fakeBin 'gh.ps1') -Encoding utf8NoBOM

    @'
param(
    [string]$WorkingDirectory,
    [int]$ReviewPr,
    [string]$PromptFile,
    [string]$ModelAlias,
    [string]$Effort,
    [string]$PermissionMode,
    [string[]]$AllowedTools = @(),
    [string]$Name
)
$promptText = if ($PromptFile) { Get-Content -LiteralPath $PromptFile -Raw } else { $null }
[ordered]@{
    WorkingDirectory = $WorkingDirectory
    ReviewPr = $ReviewPr
    PromptFile = $PromptFile
    PromptText = $promptText
    ModelAlias = $ModelAlias
    Effort = $Effort
    PermissionMode = $PermissionMode
    AllowedTools = @($AllowedTools)
    Name = $Name
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:FAKE_RUNNER_RECORD -Encoding utf8NoBOM
Write-Output 'mock review complete'
exit 0
'@ | Set-Content -LiteralPath $runnerPath -Encoding utf8NoBOM

    'review intent' | Set-Content -LiteralPath $focusFile -Encoding utf8NoBOM

    & git init --bare $origin 2>&1 | Out-Null
    & git init -b main $target 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the test repository.' }
    Invoke-Git $target @('config', 'user.name', 'Cross Review Test') | Out-Null
    Invoke-Git $target @('config', 'user.email', 'cross-review@example.invalid') | Out-Null
    'base' | Set-Content -LiteralPath (Join-Path $target 'change.txt') -Encoding utf8NoBOM
    Invoke-Git $target @('add', 'change.txt') | Out-Null
    Invoke-Git $target @('commit', '-m', 'base') | Out-Null
    Invoke-Git $target @('remote', 'add', 'origin', $origin) | Out-Null
    Invoke-Git $target @('push', '-u', 'origin', 'main') | Out-Null
    Invoke-Git $target @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main') | Out-Null
    Invoke-Git $target @('checkout', '-b', 'feature') | Out-Null
    'round one' | Set-Content -LiteralPath (Join-Path $target 'change.txt') -Encoding utf8NoBOM
    Invoke-Git $target @('add', 'change.txt') | Out-Null
    Invoke-Git $target @('commit', '-m', 'round one') | Out-Null
    $roundOneHead = (Invoke-Git $target @('rev-parse', 'HEAD') | Select-Object -First 1).Trim()

    $env:PATH = "$fakeBin$([IO.Path]::PathSeparator)$oldPath"
    $env:CODEX_HOME = $fakeCodexHome
    $env:FAKE_RUNNER_RECORD = $runnerRecord
    $env:FAKE_PR_HEAD = $roundOneHead

    $roundOne = Invoke-Controller @('-Direction', 'to-claude', '-FocusFile', $focusFile, '-ModelAlias', 'opus', '-Effort', 'medium')
    Assert-True ($roundOne.ExitCode -eq 0) "Round 1 failed: $($roundOne.Stderr)"
    $roundOneJson = $roundOne.Stdout | ConvertFrom-Json
    $roundOneRecord = Get-Content -LiteralPath $runnerRecord -Raw | ConvertFrom-Json
    Assert-True ($roundOneJson.scope -eq 'pull-request') 'Round 1 did not report pull-request scope.'
    Assert-True ($roundOneRecord.ReviewPr -eq 85) 'Round 1 did not use the built-in PR reviewer.'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$roundOneRecord.PromptFile)) 'Round 1 unexpectedly used a range prompt.'

    'round two' | Set-Content -LiteralPath (Join-Path $target 'change.txt') -Encoding utf8NoBOM
    Invoke-Git $target @('add', 'change.txt') | Out-Null
    Invoke-Git $target @('commit', '-m', 'round two') | Out-Null
    $roundTwoHead = (Invoke-Git $target @('rev-parse', 'HEAD') | Select-Object -First 1).Trim()
    $env:FAKE_PR_HEAD = $roundTwoHead

    $roundTwo = Invoke-Controller @(
        '-Direction', 'to-claude', '-FocusFile', $focusFile,
        '-Base', $roundOneHead, '-ModelAlias', 'opus', '-Effort', 'medium'
    )
    Assert-True ($roundTwo.ExitCode -eq 0) "Round 2 failed: $($roundTwo.Stderr)"
    $roundTwoJson = $roundTwo.Stdout | ConvertFrom-Json
    $roundTwoRecord = Get-Content -LiteralPath $runnerRecord -Raw | ConvertFrom-Json
    $allowedTools = @($roundTwoRecord.AllowedTools) -join ','
    Assert-True ($roundTwoJson.scope -eq 'range') 'Round 2 did not report range scope.'
    Assert-True ($roundTwoRecord.ReviewPr -eq 0) 'Round 2 reused the whole-PR reviewer.'
    Assert-True ($roundTwoRecord.PermissionMode -eq 'dontAsk') 'Round 2 did not use non-interactive read-only permissions.'
    Assert-True ($roundTwoRecord.PromptText.Contains("$roundOneHead..$roundTwoHead")) 'Round 2 prompt omitted the exact range.'
    Assert-True ($roundTwoRecord.PromptText.Contains('review intent')) 'Round 2 prompt omitted the focus text.'
    Assert-True ($roundTwoRecord.PromptText.Contains('Do not re-review the pull request')) 'Round 2 prompt omitted the no-tour rule.'
    Assert-True ($allowedTools.Contains('git diff')) 'Round 2 did not allow range inspection.'
    Assert-True (-not $allowedTools.Contains('git push')) 'Round 2 allowed a mutating Git command.'
    Assert-True (-not (Test-Path -LiteralPath ([string]$roundTwoRecord.PromptFile))) 'Round 2 left its generated prompt behind.'

    Remove-Item -LiteralPath $runnerRecord -Force
    $emptyRange = Invoke-Controller @('-Direction', 'to-claude', '-FocusFile', $focusFile, '-Base', $roundTwoHead)
    Assert-True ($emptyRange.ExitCode -eq 1) 'An empty later-round range was not rejected.'
    Assert-True (-not (Test-Path -LiteralPath $runnerRecord)) 'The reviewer ran for an empty range.'

    $gitBash = Join-Path (Split-Path -Parent (Split-Path -Parent (Get-Command git).Source)) 'bin\bash.exe'
    if (Test-Path -LiteralPath $gitBash -PathType Leaf) {
        & $gitBash -n $shellController
        Assert-True ($LASTEXITCODE -eq 0) 'The Bash entrypoint has invalid syntax.'
    }

    [ordered]@{ result = 'passed'; assertions = $assertions } | ConvertTo-Json
} finally {
    $env:PATH = $oldPath
    if ($null -eq $oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $oldCodexHome }
    if ($null -eq $oldRunnerRecord) { Remove-Item Env:FAKE_RUNNER_RECORD -ErrorAction SilentlyContinue } else { $env:FAKE_RUNNER_RECORD = $oldRunnerRecord }
    if ($null -eq $oldPrHead) { Remove-Item Env:FAKE_PR_HEAD -ErrorAction SilentlyContinue } else { $env:FAKE_PR_HEAD = $oldPrHead }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
