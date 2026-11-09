[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$hook = Join-Path (Split-Path -Parent $PSScriptRoot) 'ClosingPhrase.StopHook.ps1'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$assertionCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:assertionCount++
}

function Invoke-Hook {
    param([AllowEmptyString()][string]$InputText)
    $output = ($InputText | & $pwsh -NoProfile -ExecutionPolicy Bypass -File $hook -ManagedHookId closing-phrase-stop 2>&1 | Out-String).Trim()
    Assert-True ($LASTEXITCODE -eq 0) "The hook must always exit 0: $InputText"
    $output
}

function New-StopPayload {
    param([string]$Message, [bool]$Active = $false)
    [ordered]@{
        hook_event_name = 'Stop'; session_id = 'test-session'; stop_hook_active = $Active; last_assistant_message = $Message
    } | ConvertTo-Json -Compress
}

# Ending, the text the reason must quote, and the fix the reason must name.
$curly = 'Say ' + [char]0x201C + 'ship it' + [char]0x201D
$blocked = @(
    @('**Next:** Say "go" and I''ll merge it.', 'Say "go"', 'plain words'),
    @('**Next:** reply `merge 131` to continue.', 'reply `merge 131`', 'plain words'),
    @('Type approve 1a2b3c4 to deploy it.', 'Type approve', 'plain words'),
    @('Say the word and I''ll open the pull request.', 'Say the word', 'plain words'),
    @("$curly and I will push.", $curly, 'plain words'),
    @('**Next:** if you want, I can check the logs.', 'if you want, I can check', 'Run the check'),
    @('If you''d like, I''ll verify the rollout.', 'I''ll verify', 'Run the check'),
    @('Say if you want me to look at the failing job.', 'if you want me to look', 'Run the check'),
    @('Would you like me to verify the result?', 'Would you like me to verify', 'Run the check'),
    @('**Next:** your call on diagnosing the upload failure.', 'your call on diagnosing', 'Run the check'),
    @('I can check live if you want.', 'I can check live if you want', 'Run the check')
)
foreach ($case in $blocked) {
    $raw = Invoke-Hook (New-StopPayload $case[0])
    Assert-True ($raw -and $raw -notmatch '[^\x20-\x7E]') "A block must be one line of ASCII JSON: $($case[0])"
    $result = $raw | ConvertFrom-Json
    Assert-True ($result.decision -eq 'block') "This ending should be blocked: $($case[0])"
    Assert-True ($result.reason.Contains($case[1])) "The reason should quote the matched text '$($case[1])': $($result.reason)"
    Assert-True ($result.reason.Contains($case[2])) "The reason should say what to do ('$($case[2])'): $($result.reason)"
    Assert-True (@($result.PSObject.Properties.Name).Count -eq 2) 'A block carries only decision and reason.'
}

# Plain decisions, reported speech, offers of other work, and text before the last 500 characters pass.
$allowed = @(
    'Should I merge pull request 131? I recommend yes.',
    'Both tickets still say "Not ready" in the tracker.',
    'When the reviewer answers and you say go, I deliver the change.',
    'Sign in on the opened tab, then reply "ready".',
    '**Next:** your call on whether to restart now; I recommend waiting.',
    'If you want, I can open the pull request.',
    'Tell me if you want me to post the comment.',
    'What would you like me to inspect or change?',
    ('Say "go" and I''ll merge it. ' + ('The rest of this long report follows. ' * 20))
)
foreach ($ending in $allowed) {
    Assert-True ((Invoke-Hook (New-StopPayload $ending)) -eq '') "This ending should pass: $ending"
}

# A stop that a hook already continued, and every malformed input, must pass silently.
$message = '"last_assistant_message":"Say \"go\" and I will merge it."'
$silent = @(
    (New-StopPayload 'Say "go" and I''ll merge it.' -Active $true),
    '',
    'not json',
    '[]',
    '{}',
    '{"hook_event_name":"Stop","stop_hook_active":false}',
    '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":null}',
    '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":{"text":"Say \"go\" now."}}',
    "{`"hook_event_name`":`"Stop`",$message}",
    "{`"hook_event_name`":`"Stop`",`"stop_hook_active`":`"false`",$message}",
    "{`"hook_event_name`":`"SubagentStop`",`"stop_hook_active`":false,$message}",
    "{`"hook_event_name`":[],`"stop_hook_active`":false,$message}",
    "{`"hook_event_name`":[`"Stop`"],`"stop_hook_active`":false,$message}",
    "[{`"hook_event_name`":`"Stop`",`"stop_hook_active`":false,$message}]"
)
Assert-True ((Invoke-Hook "{`"hook_event_name`":`"Stop`",`"stop_hook_active`":false,$message}") -match '"decision":"block"') `
    'The hand-written payload shape should block when nothing is wrong with it.'
foreach ($inputText in $silent) {
    Assert-True ((Invoke-Hook $inputText) -eq '') "This input must not block or print anything: $inputText"
}

[pscustomobject]@{ result = 'passed'; assertions = $assertionCount } | ConvertTo-Json
