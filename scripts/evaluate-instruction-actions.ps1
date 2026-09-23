[CmdletBinding()]
param(
    [ValidateSet('codex', 'claude', 'all')][string]$Target = 'all',
    [string[]]$CaseId,
    [string]$OutputDirectory,
    # Replacement for Codex's built-in model instructions. The Codex client runs
    # with --ignore-user-config, so the file is passed explicitly. Defaults to
    # the manifest's reviewed Codex modelInstructions source, which is the
    # configuration the shared rules are written against.
    [string]$CodexModelInstructionsFile,
    [string]$CodexModel,
    [ValidateSet('none', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')]
    [string]$CodexReasoningEffort,
    # Evaluate Codex against its stock built-in prompt instead of the reviewed file.
    [switch]$StockCodexInstructions
)
$ErrorActionPreference = 'Stop'
if ($StockCodexInstructions -and $CodexModelInstructionsFile) { throw 'Use either -CodexModelInstructionsFile or -StockCodexInstructions, not both.' }
if ($CodexModelInstructionsFile) {
    # Resolve against PowerShell's current location, not the process directory.
    $resolvedModelFile = Resolve-Path -LiteralPath $CodexModelInstructionsFile -ErrorAction SilentlyContinue
    if (-not $resolvedModelFile -or -not (Test-Path -LiteralPath $resolvedModelFile.ProviderPath -PathType Leaf)) { throw "Codex model instructions file not found: $CodexModelInstructionsFile" }
    $CodexModelInstructionsFile = $resolvedModelFile.ProviderPath
}
# Capture native exit codes ourselves, including when a caller enables native
# ErrorActionPreference integration. Preserve stdout before reporting failures.
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'AgentCustomization.Common.ps1')
. (Join-Path $PSScriptRoot 'InstructionActions.Common.ps1')
$repo = Get-CustomizationRepositoryRoot
$manifest = Get-CustomizationManifest
if (-not $CodexModelInstructionsFile -and -not $StockCodexInstructions -and $null -ne $manifest.targets.codex.PSObject.Properties['modelInstructions']) {
    $CodexModelInstructionsFile = Join-Path $repo ([string]$manifest.targets.codex.modelInstructions.source)
    if (-not (Test-Path -LiteralPath $CodexModelInstructionsFile -PathType Leaf)) { throw "Reviewed Codex model instructions file not found: $CodexModelInstructionsFile" }
}
$fixtures = Join-Path $repo 'tests/fixtures'
$cases = (Get-Content (Join-Path $fixtures 'instruction-action-cases.json') -Raw | ConvertFrom-Json).cases
$expectations = Get-Content (Join-Path $fixtures 'instruction-action-expectations.json') -Raw | ConvertFrom-Json
$schemaPath = Join-Path $fixtures 'instruction-action-response.schema.json'
$schema = Get-Content $schemaPath -Raw
$CaseId = @($CaseId | ForEach-Object { $_ -split ',' } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($PSBoundParameters.ContainsKey('CaseId') -and -not $CaseId.Count) { throw 'CaseId was supplied but contains no case names.' }
if (@($CaseId | Where-Object { $_ -notin $cases.id }).Count) { throw 'Unknown action case.' }
if ($CaseId.Count) { $cases = @($cases | Where-Object id -in $CaseId) }
$targets = if ($Target -eq 'all') { @('codex', 'claude') } else { @($Target) }
foreach ($client in $targets) {
    if (-not (Get-Command $client -ErrorAction SilentlyContinue)) {
        throw "Required action client is unavailable: $client"
    }
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('instruction-actions-' + [guid]::NewGuid().ToString('N')) }
$OutputDirectory = Resolve-ActionOutputDirectory $OutputDirectory
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
# Each run uses its own child so an existing output directory is never a workspace.
$runRoot = Join-Path $OutputDirectory ([guid]::NewGuid().ToString('N'))
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
            $stderrPath = Join-Path $caseRoot "client-$step.stderr.txt"
            $prompt | Set-Content (Join-Path $caseRoot "prompt-$step.txt")
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
                if ($CodexModel) { $arguments += @('--model', $CodexModel) }
                if ($CodexReasoningEffort) { $arguments += @('-c', ('model_reasoning_effort="' + $CodexReasoningEffort + '"')) }
                if ($CodexModelInstructionsFile) { $arguments += @('-c', ('model_instructions_file="' + ($CodexModelInstructionsFile -replace '\\', '/') + '"')) }
                $raw = @($prompt | & codex @arguments '-' 2> $stderrPath)
                $clientExit = $LASTEXITCODE
                $raw | Set-Content (Join-Path $caseRoot "client-$step.jsonl")
                if ($clientExit -ne 0) { throw "Codex action client failed with exit $clientExit; diagnostics: $stderrPath" }
                foreach ($line in $raw) {
                    $event = $line | ConvertFrom-Json
                    if ($event.type -like 'item.*' -and $event.item.type -eq 'error') {
                        throw "Codex client reported: $($event.item.message)"
                    }
                    if ($event.type -like 'item.*' -and $event.item.type -notin @('agent_message','reasoning')) {
                        throw (New-ActionProtocolException "Native CLI action is outside the controlled protocol: $($event.item.type)")
                    }
                }
                return Get-Content $responsePath -Raw | ConvertFrom-Json
            }
            Push-Location $workspace
            try {
                $raw = @(& claude --print --no-session-persistence --permission-mode dontAsk --setting-sources '' `
                    --disable-slash-commands --tools '' --strict-mcp-config --mcp-config $mcpConfig `
                    --system-prompt-file $instructionsPath --json-schema $schema --output-format json $prompt 2> $stderrPath)
                $clientExit = $LASTEXITCODE
            } finally { Pop-Location }
            $raw | Set-Content (Join-Path $caseRoot "client-$step.json")
            if ($clientExit -ne 0) { throw "Claude action client failed with exit $clientExit; diagnostics: $stderrPath" }
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
            $kind = if ($_.Exception.Data['failureKind'] -eq 'protocol') { 'protocol' } else { 'execution' }
            $results.Add(@{target = $agentTarget; case = $case.id; passed = $false; failureKind = $kind; errors = @($_.Exception.Message)})
        }
        Write-Host "$agentTarget/$($case.id): $($results[$results.Count - 1] | ConvertTo-Json -Compress)"
    }
}
$summary = @{codexModel = $CodexModel; codexReasoningEffort = $CodexReasoningEffort; results = $results.ToArray(); passed = @($results | Where-Object passed).Count; failed = @($results | Where-Object { -not $_.passed }).Count; artifacts = $runRoot}
$summary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $runRoot 'summary.json')
$summary | ConvertTo-Json -Depth 8
if ($summary.failed) { exit 1 }
