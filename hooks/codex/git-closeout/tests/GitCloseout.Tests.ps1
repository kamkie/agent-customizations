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

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("git closeout tests " + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $testRoot 'repo'
$hook = Join-Path $testRoot 'GitCloseout.Hook.ps1'
$stop = @{ stop_hook_active = $false; last_assistant_message = 'Done. Nothing remains.' }
$null = [IO.Directory]::CreateDirectory($repo)
try {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../GitCloseout.Hook.ps1') -Destination $hook
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

    $prompt = 'UserPromptSubmit'
    foreach ($text in @('Is this merged?', 'The tool log prints "merged".', 'Merge this PR')) {
        Assert-That ($null -eq (Invoke-Hook $prompt @{ prompt = $text })) "Out-of-scope prompt armed the hook: $text"
    }
    Assert-That ($null -eq (Invoke-Hook Stop $stop)) 'An ordinary turn must not get a Git closeout gate.'

    $activation = Invoke-Hook $prompt @{ prompt = 'Merged!' }
    $context = $activation.hookSpecificOutput.additionalContext
    $key = [regex]::Match($context, "-Record '([a-f0-9]{64})'").Groups[1].Value
    Assert-That ($key.Length -eq 64) 'A short merge report must arm the hook and provide a record command.'
    Assert-That ($null -eq (Invoke-Hook Stop $stop -Session 'other-delivery')) 'State leaked across sessions.'
    Assert-That ($null -eq (Invoke-Hook Stop $stop -Turn 'other-turn')) 'State leaked across turns.'

    $missing = Invoke-Hook Stop $stop
    Assert-That ($missing.decision -eq 'block' -and $missing.reason -match 'inventory') 'A premature completion would have passed without a record.'
    & $hook -Record $key -TurnId 'merge-turn' -LandedCommit $landed -TaskBranch @('task-topic', 'earlier-task-topic')
    Assert-That ($LASTEXITCODE -eq 0) 'Could not write the branch inventory.'
    & $hook -Record $key -TurnId 'merge-turn' -LandedCommit $landed -TaskBranch @('earlier-task-topic', 'task-topic')
    Assert-That ($LASTEXITCODE -eq 0) 'An idempotent retry must accept the same inventory.'

    $stale = Invoke-Hook Stop $stop
    Assert-That ($stale.decision -eq 'block' -and $stale.reason -match 'contain the reported merge') 'Local main matching a stale origin/main must fail.'
    Invoke-Git @('update-ref', 'refs/remotes/origin/main', $landed)
    $behind = Invoke-Hook Stop $stop
    Assert-That ($behind.reason -match 'does not match' -and $behind.reason -match 'earlier-task-topic' -and $behind.reason -match '(?<!earlier-)task-topic') 'The Stop hook missed stale main or a recorded branch.'
    Assert-That ((Invoke-Git @('rev-parse', 'main')) -eq $base) 'A hook mutated local main.'
    Assert-That ((Invoke-Git @('status', '--porcelain')) -eq $null) 'A hook changed the checkout.'

    Invoke-Git @('merge', '-q', '--ff-only', 'origin/main')
    Invoke-Git @('branch', '-d', 'task-topic', 'earlier-task-topic')
    Set-Content -LiteralPath (Join-Path $repo 'untracked.txt') -Value 'user work'
    $dirty = Invoke-Hook Stop $stop
    Assert-That ($dirty.decision -eq 'block' -and $dirty.reason -match 'checkout has changes') 'A dirty main checkout passed.'
    $warning = Invoke-Hook Stop @{ stop_hook_active = $true }
    Assert-That ($null -eq $warning.decision -and $warning.systemMessage -match 'checkout has changes') 'A blocked closeout must surface the remaining issue and stop retrying.'
    Assert-That ((Get-Content -LiteralPath (Join-Path $repo 'untracked.txt')) -eq 'user work') 'The hook changed user work.'
    Remove-Item -LiteralPath (Join-Path $repo 'untracked.txt')

    $again = Invoke-Hook $prompt @{ prompt = 'scalone MR !42' } -Turn 'resume-turn'
    $againKey = [regex]::Match($again.hookSpecificOutput.additionalContext, "-Record '([a-f0-9]{64})'").Groups[1].Value
    & $hook -Record $againKey -TurnId 'resume-turn' -LandedCommit $landed -TaskBranch @()
    & $hook -Record $againKey -TurnId 'resume-turn' -LandedCommit $landed -TaskBranch @()
    Assert-That ($null -eq (Invoke-Hook Stop $stop -Turn 'resume-turn')) 'Verified Git state should pass.'
    Assert-That ((Invoke-Git @('branch', '--list', 'another-session')).Trim() -eq 'another-session') 'An unrelated branch was changed.'
    Assert-That (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'state') -File).Count -eq 0) 'Closeout records should be consumed.'
    Write-Host 'Git closeout hook tests passed.'
} finally {
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
