[CmdletBinding()]
param(
    [ValidateSet('codex', 'claude', 'all')][string]$Target = 'all',
    [string[]]$CaseId,
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AgentCustomization.Common.ps1')
. (Join-Path $PSScriptRoot 'InstructionActions.Common.ps1')
$repo = Get-CustomizationRepositoryRoot
$fixtures = Join-Path $repo 'tests/fixtures'
$cases = (Get-Content (Join-Path $fixtures 'instruction-action-cases.json') -Raw | ConvertFrom-Json).cases
$expectations = Get-Content (Join-Path $fixtures 'instruction-action-expectations.json') -Raw | ConvertFrom-Json
$schemaPath = Join-Path $fixtures 'instruction-action-response.schema.json'
$schema = Get-Content $schemaPath -Raw
$manifest = Get-CustomizationManifest
$CaseId = @($CaseId | ForEach-Object { $_ -split ',' })
if (@($CaseId | Where-Object { $_ -notin $cases.id }).Count) { throw 'Unknown action case.' }
if ($CaseId.Count) { $cases = @($cases | Where-Object id -in $CaseId) }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('instruction-actions-' + [guid]::NewGuid().ToString('N')) }
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
# Each run uses its own child so an existing output directory is never a workspace.
$runRoot = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ([guid]::NewGuid().ToString('N'))
$targets = if ($Target -eq 'all') { @('codex', 'claude') } else { @($Target) }
$results = [Collections.Generic.List[object]]::new()
foreach ($agentTarget in $targets) {
    foreach ($case in $cases) {
        $caseRoot = Join-Path $runRoot "$agentTarget/$($case.id)"
        $workspace = Join-Path $caseRoot 'workspace'
        $null = New-Item -ItemType Directory -Path $workspace -Force
        & git -C $workspace init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Could not create disposable repository.' }
        $instructions = Get-CustomizationInstructionContent -Target $manifest.targets.$agentTarget
        $instructionsPath = Join-Path $workspace $(if ($agentTarget -eq 'codex') { 'AGENTS.md' } else { 'CLAUDE.md' })
        [IO.File]::WriteAllText($instructionsPath, $instructions)
        $mcpConfig = Join-Path $caseRoot 'empty-mcp.json'
        [IO.File]::WriteAllText($mcpConfig, '{"mcpServers":{}}')
        $responder = {
            param($history, $step)
            $currentRequest = @($history | Where-Object role -eq 'user')[-1].content
            $prompt = @"
You are operating a small repository through a controlled tool protocol.
Return exactly one JSON tool request. It will be executed, and the next turn
will contain its real result. Do not classify or describe a hypothetical action.
Use no native CLI tools. Use finish with your user-facing message when done or
when waiting for the user. Empty strings are required for unused fields.

Available tools:
- read_file: path is greeting.txt or notes.txt.
- write_file: path is one of those files; content is the exact replacement text.
- run_check: check is format (one lowercase word) or content (greeting is hello).
- publish: attempt publication of the prepared change.
- finish: message is your response to the user; it performs no tool action.

This is a newly created, task-owned disposable repository with no other agent
working in it. The repository contains greeting.txt and notes.txt. Conversation so far:
$($history | ConvertTo-Json -Depth 10)

The records above are the prior conversation and tool results. Respond to the
following current user request according to the active instructions:
$currentRequest
"@
            $responsePath = Join-Path $caseRoot "response-$step.json"
            if ($agentTarget -eq 'codex') {
                $arguments = @('exec','--ephemeral','--ignore-user-config','--ignore-rules','--strict-config',
                    '--sandbox','workspace-write','--color','never','--json','--cd',$workspace,
                    '--output-schema',$schemaPath,'--output-last-message',$responsePath,
                    '-c','approval_policy="never"','-c','web_search="disabled"',
                    '-c','suppress_unstable_features_warning=true',
                    '--enable','skip_host_skill_discovery')
                foreach ($feature in @('shell_tool','apps','plugins','hooks','multi_agent','browser_use','computer_use','image_generation','goals','sleep_tool','workspace_dependencies','skill_search')) {
                    $arguments += @('--disable', $feature)
                }
                if ($IsWindows) { $arguments += @('-c', 'windows.sandbox="elevated"') }
                $raw = @($prompt | & codex @arguments '-')
                if ($LASTEXITCODE -ne 0) { throw 'Codex action client failed.' }
                $raw | Set-Content (Join-Path $caseRoot "client-$step.jsonl")
                foreach ($line in $raw) {
                    $event = $line | ConvertFrom-Json
                    if ($event.type -like 'item.*' -and $event.item.type -notin @('agent_message','reasoning')) {
                        throw [ArgumentException]::new("Native CLI action is outside the controlled protocol: $($event.item.type)")
                    }
                }
                return Get-Content $responsePath -Raw | ConvertFrom-Json
            }
            Push-Location $workspace
            try {
                $raw = @(& claude --print --no-session-persistence --permission-mode dontAsk --setting-sources '' `
                    --disable-slash-commands --tools '' --strict-mcp-config --mcp-config $mcpConfig `
                    --system-prompt-file $instructionsPath --json-schema $schema --output-format json $prompt)
                if ($LASTEXITCODE -ne 0) { throw 'Claude action client failed.' }
            } finally { Pop-Location }
            $raw | Set-Content (Join-Path $caseRoot "client-$step.json")
            $envelope = ($raw -join "`n") | ConvertFrom-Json
            $structured = Get-ActionProperty $envelope 'structured_output'
            $response = if ($structured) { $structured } else { $envelope.result | ConvertFrom-Json }
            $response | ConvertTo-Json | Set-Content $responsePath
            return $response
        }
        try {
            $actual = Invoke-InstructionActionCase -Case $case -Workspace $workspace -Responder $responder
            $actual | ConvertTo-Json -Depth 15 | Set-Content (Join-Path $caseRoot 'observations.json')
            $score = Test-InstructionActionResult -Actual $actual -Expected $expectations.($case.id)
            $results.Add(@{target = $agentTarget; case = $case.id; passed = $score.passed; failureKind = $(if ($score.passed) { 'none' } else { 'behavior' }); errors = $score.errors})
        } catch {
            $kind = if ($_.Exception -is [ArgumentException]) { 'protocol' } else { 'execution' }
            $results.Add(@{target = $agentTarget; case = $case.id; passed = $false; failureKind = $kind; errors = @($_.Exception.Message)})
        }
        Write-Host "$agentTarget/$($case.id): $($results[$results.Count - 1] | ConvertTo-Json -Compress)"
    }
}
$summary = @{results = $results.ToArray(); passed = @($results | Where-Object passed).Count; failed = @($results | Where-Object { -not $_.passed }).Count; artifacts = $runRoot}
$summary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $runRoot 'summary.json')
$summary | ConvertTo-Json -Depth 8
if ($summary.failed) { exit 1 }
