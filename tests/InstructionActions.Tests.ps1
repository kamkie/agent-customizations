[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../scripts/InstructionActions.Common.ps1')
$cases = (Get-Content (Join-Path $PSScriptRoot 'fixtures/instruction-action-cases.json') -Raw | ConvertFrom-Json).cases
$expected = Get-Content (Join-Path $PSScriptRoot 'fixtures/instruction-action-expectations.json') -Raw | ConvertFrom-Json
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('instruction-actions-test-' + [guid]::NewGuid().ToString('N'))
$assertions = 0
function Assert-True($condition, $message) {
    if (-not $condition) { throw $message }
    $script:assertions++
}
function Action($tool, $path = '', $content = '', $check = '') {
    return [pscustomobject]@{tool = $tool; path = $path; content = $content; check = $check; message = 'Complete.'}
}
function Replay($id, $requests) {
    $workspace = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $workspace -Force
    & git -C $workspace init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Disposable git repository failed.' }
    $sequence = $requests
    $respond = { param($history, $step) return $sequence[[Math]::Min($step, $sequence.Count - 1)] }.GetNewClosure()
    $case = $cases | Where-Object id -eq $id
    $actual = Invoke-InstructionActionCase -Case $case -Workspace $workspace -Responder $respond
    return @{actual = $actual; score = (Test-InstructionActionResult $actual $expected.$id)}
}
try {
    Assert-True ($cases.Count -eq @($cases.id | Select-Object -Unique).Count) 'Duplicate action cases.'
    Assert-True (-not (Compare-Object @($cases.id | Sort-Object) @($expected.PSObject.Properties.Name | Sort-Object))) 'Cases and expectations differ.'
    $finish = Action 'finish'
    $write = Action 'write_file' 'greeting.txt' 'hello'
    $format = Action 'run_check' '' '' 'format'
    $content = Action 'run_check' '' '' 'content'
    $publish = Action 'publish'
    $notes = Action 'write_file' 'notes.txt' 'checked'
    $plans = @{
        'design-agreement' = @($finish)
        'explicit-implementation' = @((Action 'read_file' 'greeting.txt'), $finish, $write, $content, $finish)
        'continue-after-check' = @($write, $format, $content, $finish)
        'stop-after-write' = @($write, $finish)
        'publication-blocked' = @($publish, $notes, $format, $content, $finish)
    }
    foreach ($id in $plans.Keys) {
        $result = Replay $id $plans[$id]
        Assert-True $result.score.passed "Valid action sequence rejected for $id : $($result.score.errors)"
    }
    $result = Replay 'design-agreement' @($write, (Action 'write_file' 'greeting.txt' 'helo'), $finish)
    Assert-True (-not $result.score.passed) 'A write then rollback during design passed.'
    $result = Replay 'explicit-implementation' @($write, $finish, $content, $finish)
    Assert-True (-not $result.score.passed) 'Mutation before explicit authorization passed.'
    $result = Replay 'continue-after-check' @($write, $format, $finish)
    Assert-True (-not $result.score.passed) 'Stopping after only the first check passed.'
    $result = Replay 'stop-after-write' @($write, (Action 'read_file' 'notes.txt'), $finish)
    Assert-True ($result.actual.afterStopCalls -eq 1 -and -not $result.score.passed) 'Read-only call after stop was not detected.'
    $result = Replay 'publication-blocked' @($publish, $finish)
    Assert-True (-not $result.score.passed) 'Abandoning independent work after blocked publication passed.'
    $result = Replay 'continue-after-check' @($write, $format, $content, (Action 'write_file' 'greeting.txt' 'bye'), $finish)
    Assert-True (@($result.score.errors | Where-Object { $_ -like 'No passing check on final content*' }).Count -eq 2) 'Stale check results were accepted.'
    $result = Replay 'continue-after-check' @((Action 'read_file' 'greeting.txt'))
    Assert-True (-not $result.actual.finished -and -not $result.score.passed) 'Action exhaustion claimed completion.'
    $rejected = $false
    try { Replay 'design-agreement' @((Action 'write_file' '../outside.txt' 'bad')) | Out-Null } catch {
        $rejected = $_.Exception -is [ArgumentException] -and $_.Exception.Message -like '*outside the tool allowlist*'
    }
    Assert-True $rejected 'Path traversal was not rejected.'
    Assert-True (-not (Test-Path (Join-Path $testRoot 'outside.txt'))) 'Path traversal wrote outside the workspace.'
    $rejected = $false
    try { Replay 'design-agreement' @((Action 'read_file' 'Greeting.txt')) | Out-Null } catch {
        $rejected = $_.Exception -is [ArgumentException]
    }
    Assert-True $rejected 'A noncanonical filename was not classified as a protocol violation.'
    $occupied = Join-Path $testRoot 'occupied'
    $null = New-Item -ItemType Directory -Path $occupied
    [IO.File]::WriteAllText((Join-Path $occupied 'notes.txt'), 'existing')
    $rejected = $false
    try { Invoke-InstructionActionCase -Case $cases[0] -Workspace $occupied -Responder { $finish } | Out-Null } catch {
        $rejected = $_.Exception.Message -like '*pre-existing fixture files*'
    }
    Assert-True ($rejected -and -not (Test-Path (Join-Path $occupied 'greeting.txt'))) 'Occupied workspace was partially initialized.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $occupied 'notes.txt')) -ceq 'existing') 'Occupied workspace contents were overwritten.'
    $pwsh = (Get-Command pwsh).Source
    $runner = Join-Path $PSScriptRoot '../scripts/evaluate-instruction-actions.ps1'
    $missingOutput = Join-Path $testRoot 'missing-client'
    $savedPath = $env:PATH
    try {
        $env:PATH = ''
        $missing = @(& $pwsh -NoProfile -File $runner -Target codex -OutputDirectory $missingOutput 2>&1)
        $missingExit = $LASTEXITCODE
    } finally { $env:PATH = $savedPath }
    Assert-True ($missingExit -ne 0 -and ($missing -join ' ') -match 'Required action client is unavailable: codex') 'Missing client was not identified during preflight.'
    Assert-True (-not (Test-Path $missingOutput)) 'Missing client created case artifacts or behavior results.'
    Write-Host "Instruction action dispatcher and observation tests: OK ($assertions assertions)"
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
