$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Assert-That([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Git([string[]]$Arguments) {
    $output = git -C $repo @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Git failed: $($Arguments -join ' ')" }
    $output
}

function Invoke-Hook($Event, $Fields, $Session = 'delivery', $Turn = 'merge-turn') {
    $payload = @{
        hook_event_name = $Event
        session_id = $Session
        turn_id = $Turn
        cwd = $repo
    } + $Fields | ConvertTo-Json -Compress
    $output = $payload | pwsh -NoProfile -File $hook
    if ($LASTEXITCODE -ne 0) { throw "Hook failed: $Event" }
    if ($output) { $output | ConvertFrom-Json }
}

function Get-InventoryPath($Activation) {
    $context = $Activation.hookSpecificOutput.additionalContext
    $match = [regex]::Match($context, '(?m)^Inventory path: (.+)$')
    if (-not $match.Success) { throw 'The merge prompt did not provide an inventory path.' }
    $path = $match.Groups[1].Value.TrimEnd("`r")
    Assert-That ((Split-Path -Parent $path) -eq $stateRoot) 'The inventory must be writable under the session temp directory.'
    $path
}

function Write-Inventory($Path, $Branches = @(), $Worktrees = @()) {
    $plan = @{ landedCommit = $landed; branches = @($Branches); worktrees = @($Worktrees); mainCheckout = $repo }
    $plan | ConvertTo-Json -Compress | Set-Content -LiteralPath $Path -Encoding utf8
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("git closeout tests " + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $testRoot 'Łódź repo'
$aux = Join-Path $testRoot 'task checkout'
$hook = Join-Path $PSScriptRoot '../GitCloseout.Hook.ps1'
$stateRoot = Join-Path $testRoot 'codex-git-closeout'
$stop = @{ stop_hook_active = $false; last_assistant_message = 'Done. Nothing remains.' }
$savedTemp = @{}
$null = [IO.Directory]::CreateDirectory($repo)
try {
    foreach ($name in @('TEMP', 'TMP', 'TMPDIR')) {
        $savedTemp[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $testRoot)
    }
    Invoke-Git @('-c', 'core.hideDotFiles=false', 'init', '-q', '-b', 'main')
    Invoke-Git @('config', 'user.name', 'Closeout Test')
    Invoke-Git @('config', 'user.email', 'test@example.invalid')
    Invoke-Git @('remote', 'add', 'origin', (Join-Path $testRoot 'origin.git'))
    Invoke-Git @('commit', '-q', '--allow-empty', '-m', 'base')
    $base = Invoke-Git @('rev-parse', 'HEAD')
    Invoke-Git @('update-ref', 'refs/remotes/origin/main', $base)
    Invoke-Git @('branch', 'another-session')
    Invoke-Git @('switch', '-q', '-c', 'task-topic')
    Invoke-Git @('commit', '-q', '--allow-empty', '-m', 'landed')
    $landed = Invoke-Git @('rev-parse', 'HEAD')
    Invoke-Git @('branch', 'earlier-task-topic')
    Invoke-Git @('switch', '-q', 'main')
    Invoke-Git @('worktree', 'add', '-q', '--detach', $aux, $landed)

    $prompt = 'UserPromptSubmit'
    foreach ($text in @('Is this merged?', 'The tool log prints "merged".', 'Merge this PR')) {
        Assert-That ($null -eq (Invoke-Hook $prompt @{ prompt = $text })) "Out-of-scope prompt armed the hook: $text"
    }
    Assert-That ($null -eq (Invoke-Hook Stop $stop)) 'An ordinary turn must not get a Git closeout gate.'
    foreach ($text in @('PR 202 merged', 'merged PR 202', 'merged, thanks', 'it''s merged', 'scalone MR !42')) {
        $null = Get-InventoryPath (Invoke-Hook $prompt @{ prompt = $text })
        $null = Invoke-Hook SessionEnd @{}
    }

    $inventory = Get-InventoryPath (Invoke-Hook $prompt @{ prompt = 'Merged!' })
    Assert-That ($null -eq (Invoke-Hook Stop $stop -Session 'other-delivery')) 'State leaked across sessions.'
    Assert-That ($null -eq (Invoke-Hook Stop $stop -Turn 'other-turn')) 'State leaked across turns.'

    $missing = Invoke-Hook Stop $stop
    Assert-That ($missing.decision -eq 'block' -and $missing.reason -match 'inventory') 'A premature completion would have passed without a record.'
    Set-Content -LiteralPath $inventory -Value '{' -Encoding utf8
    Assert-That ((Invoke-Hook Stop $stop).decision -eq 'block') 'An invalid inventory must report a recoverable error.'
    Write-Inventory $inventory @('task-topic', 'earlier-task-topic', 'another-session') @($aux)
    Write-Inventory $inventory @('task-topic', 'earlier-task-topic') @($aux)

    $stale = Invoke-Hook Stop $stop
    Assert-That ($stale.decision -eq 'block' -and $stale.reason -match 'contain the reported merge') 'Local main matching a stale origin/main must fail.'
    Invoke-Git @('update-ref', 'refs/remotes/origin/main', $landed)
    $behind = Invoke-Hook Stop $stop
    Assert-That ($behind.reason -match 'does not match' -and $behind.reason -match 'earlier-task-topic' -and $behind.reason -match '(?<!earlier-)task-topic') 'The Stop hook missed stale main or a recorded branch.'
    Assert-That ($behind.reason -notmatch 'another-session') 'A corrected inventory still carries an unrelated branch.'
    Assert-That ((Invoke-Git @('rev-parse', 'main')) -eq $base) 'A hook mutated local main.'
    Assert-That ((Invoke-Git @('status', '--porcelain')) -eq $null) 'A hook changed the checkout.'

    Invoke-Git @('merge', '-q', '--ff-only', 'origin/main')
    Invoke-Git @('branch', '-d', 'task-topic', 'earlier-task-topic')
    $leftover = Invoke-Hook Stop $stop
    Assert-That ($leftover.decision -eq 'block' -and $leftover.reason -match 'worktree still exists') 'A detached task worktree passed.'
    Invoke-Git @('worktree', 'remove', $aux)
    Invoke-Git @('switch', '-q', '--detach')
    Assert-That ((Invoke-Hook Stop $stop).reason -match 'has not been restored') 'A detached reusable checkout passed.'
    Invoke-Git @('switch', '-q', 'main')

    Set-Content -LiteralPath (Join-Path $repo 'untracked.txt') -Value 'user work'
    $dirty = Invoke-Hook Stop $stop
    Assert-That ($dirty.decision -eq 'block' -and $dirty.reason -match 'checkout has changes') 'A dirty main checkout passed.'
    $warning = Invoke-Hook Stop @{ stop_hook_active = $true }
    Assert-That ($null -eq $warning.decision -and $warning.systemMessage -match 'checkout has changes') 'A blocked closeout must surface the remaining issue and stop retrying.'
    Assert-That ((Get-Content -LiteralPath (Join-Path $repo 'untracked.txt')) -eq 'user work') 'The hook changed user work.'
    Remove-Item -LiteralPath (Join-Path $repo 'untracked.txt')

    $interrupted = Get-InventoryPath (Invoke-Hook $prompt @{ prompt = 'merged' } -Turn 'interrupted-turn')
    Write-Inventory $interrupted
    $null = Invoke-Hook $prompt @{ prompt = 'continue' } -Turn 'follow-up'
    Assert-That (-not (Test-Path -LiteralPath $interrupted)) 'A later turn did not release the interrupted inventory.'

    $again = Get-InventoryPath (Invoke-Hook $prompt @{ prompt = 'merged' } -Turn 'resume-turn')
    Write-Inventory $again
    Assert-That ($null -eq (Invoke-Hook Stop $stop -Turn 'resume-turn')) 'Verified Git state should pass.'
    Assert-That ((Invoke-Git @('branch', '--list', 'another-session')).Trim() -eq 'another-session') 'An unrelated branch was changed.'
    Assert-That (@(Get-ChildItem -LiteralPath $stateRoot -File).Count -eq 0) 'Closeout records should be consumed.'
    Write-Host 'Git closeout hook tests passed.'
} finally {
    foreach ($name in $savedTemp.Keys) { [Environment]::SetEnvironmentVariable($name, $savedTemp[$name]) }
    $resolved = (Resolve-Path -LiteralPath $testRoot).Path
    if ($resolved -ne [IO.Path]::GetFullPath($testRoot)) { throw "Unexpected test cleanup path: $resolved" }
    try {
        Remove-Item -LiteralPath $resolved -Recurse
    } catch {
        $incidental = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::ReadOnly
        $items = @(Get-ChildItem -LiteralPath $resolved -Recurse -Force | Where-Object {
            ($_.Attributes -band $incidental) -and -not ($_.Attributes -band [IO.FileAttributes]::System)
        })
        if (-not $items.Count) { throw }
        foreach ($item in $items) { $item.Attributes = $item.Attributes -band (-bnot $incidental) }
        Remove-Item -LiteralPath $resolved -Recurse
    }
}
