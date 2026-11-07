[CmdletBinding()]
param(
    [ValidateSet('codex', 'claude', 'all')]
    [string]$Target = 'all',

    # behavior scores global-guidance decisions; skill-routing scores which
    # installed skill a fresh agent would load for each request.
    [ValidateSet('behavior', 'skill-routing')]
    [string]$Suite = 'behavior',

    [Alias('Case')]
    [string[]]$CaseId,

    [string]$ResponseDirectory,

    [string]$OutputDirectory,

    # Replacement for Codex's built-in model instructions. The Codex client runs
    # with --ignore-user-config, so the file is passed explicitly. Defaults to
    # the manifest's reviewed Codex modelInstructions source, which is the
    # configuration the shared rules are written against.
    [string]$CodexModelInstructionsFile,
    [string]$CodexModel,
    [ValidateSet('none', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')]
    [string]$CodexReasoningEffort,
    # Claude model alias or ID, such as haiku, sonnet, or opus.
    [string]$ClaudeModel,
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')]
    [string]$ClaudeEffort,

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
. (Join-Path $PSScriptRoot 'AgentCustomization.Common.ps1')
. (Join-Path $PSScriptRoot 'InstructionEvaluation.Common.ps1')
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$manifest = Get-CustomizationManifest
if (-not $CodexModelInstructionsFile -and -not $StockCodexInstructions -and $null -ne $manifest.targets.codex.PSObject.Properties['modelInstructions']) {
    $CodexModelInstructionsFile = Join-Path $repositoryRoot ([string]$manifest.targets.codex.modelInstructions.source)
    if (-not (Test-Path -LiteralPath $CodexModelInstructionsFile -PathType Leaf)) { throw "Reviewed Codex model instructions file not found: $CodexModelInstructionsFile" }
}
$fixtureRoot = Join-Path $repositoryRoot 'tests\fixtures'
$fixturePrefix = if ($Suite -eq 'skill-routing') { 'skill-routing' } else { 'instruction-behavior' }
$casesPath = Join-Path $fixtureRoot "$fixturePrefix-cases.json"
$expectationsPath = Join-Path $fixtureRoot "$fixturePrefix-expectations.json"
$schemaPath = Join-Path $fixtureRoot "$fixturePrefix-response.schema.json"

$caseDocument = Get-Content -LiteralPath $casesPath -Raw | ConvertFrom-Json
$expectationDocument = Get-Content -LiteralPath $expectationsPath -Raw | ConvertFrom-Json
$schema = Get-Content -LiteralPath $schemaPath -Raw
$schemaDocument = $schema | ConvertFrom-Json
$CaseId = @($CaseId | ForEach-Object { $_ -split ',' } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($PSBoundParameters.ContainsKey('CaseId') -and -not $CaseId.Count) { throw 'CaseId was supplied but contains no case names.' }
$requestedTargets = if ($Target -eq 'all') { @('codex', 'claude') } else { @($Target) }
$selectedCases = @($caseDocument.cases | Where-Object {
    (-not $CaseId -or $_.id -in $CaseId) -and
    (@($_.targets | Where-Object { $_ -in $requestedTargets }).Count -gt 0)
})

if ($selectedCases.Count -eq 0) {
    throw "No $Suite cases matched the requested target and case filters."
}
if ($CaseId) {
    $missingCases = @($CaseId | Where-Object { $_ -notin @($caseDocument.cases.id) })
    if ($missingCases.Count -gt 0) {
        throw "Unknown $Suite case(s): " + ($missingCases -join ', ')
    }
}

if (-not $ResponseDirectory) {
    foreach ($client in $requestedTargets) {
        if (-not (Get-Command $client -ErrorAction SilentlyContinue)) { throw "Required evaluation client is unavailable: $client" }
    }
}
$resolvedOutputDirectory = New-EvaluationRunDirectory $OutputDirectory
$modelInstructionMode = if ($StockCodexInstructions) { 'stock' } elseif ($PSBoundParameters.ContainsKey('CodexModelInstructionsFile')) { 'custom' } else { 'reviewed' }
$baseline = Save-EvaluationModelInstructions -RunRoot $resolvedOutputDirectory -Source $CodexModelInstructionsFile -Mode $modelInstructionMode
$CodexModelInstructionsFile = $baseline.snapshot

function Write-CompiledInstructions {
    param(
        [Parameter(Mandatory)][string]$AgentTarget,
        [Parameter(Mandatory)][string]$InstructionSet,
        [Parameter(Mandatory)][string]$Destination
    )

    $targetProperty = $manifest.targets.PSObject.Properties[$AgentTarget]
    if (-not $targetProperty) { throw "Unsupported instruction target: $AgentTarget" }
    $content = Get-CustomizationInstructionContent -Target $targetProperty.Value

    switch ($InstructionSet) {
        'global' { }
        'review' {
            $skillPath = Join-Path $repositoryRoot 'skills\cross-agent-review\SKILL.md'
            $content = $content.TrimEnd() + "`n`n" + [IO.File]::ReadAllText($skillPath) + "`n"
        }
        'campaign' {
            if ($AgentTarget -ne 'codex') {
                throw "Instruction set '$InstructionSet' is not supported for target '$AgentTarget'."
            }
            $skillPath = Join-Path $repositoryRoot 'skills\orchestrate-work-campaigns\SKILL.md'
            $skill = [IO.File]::ReadAllText($skillPath).Replace("`r`n", "`n").TrimEnd([char[]]"`r`n")
            $content = $content.TrimEnd([char[]]"`r`n") + "`n`n" + $skill + "`n"
        }
        'skill-catalog' {
            # Mirror the agent's skill listing: routing sees only names and descriptions.
            $catalog = foreach ($skillName in @($targetProperty.Value.skills)) {
                $frontmatter = Get-SkillFrontmatter -Path (Join-Path $repositoryRoot "skills\$skillName\SKILL.md")
                "- $($frontmatter.name): $($frontmatter.description)"
            }
            $content = $content.TrimEnd([char[]]"`r`n") + "`n`n## Available skills`n`n" + ($catalog -join "`n") + "`n"
        }
        default { throw "Unknown instruction set: $InstructionSet" }
    }
    [IO.File]::WriteAllText(
        $Destination,
        $content,
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-EvaluationPrompt {
    param([Parameter(Mandatory)]$Case)

    if ($Suite -eq 'skill-routing') {
        return @"
This is a read-only skill-routing evaluation. Do not use tools or change any
state. The active instructions end with the available skills and their routing
descriptions. Choose the one skill you would load first to handle the request,
or none when no listed skill applies. Return only the JSON object required by
the response schema.

Request:
$($Case.prompt)
"@
    }

    return @"
This is a read-only behavioral evaluation of the active instructions. Do not
use tools or change any state. Classify how the request must be handled and
return only the JSON object required by the response schema.

publicationAuthorized means the request and active instructions authorize a
remote branch plus a pull or merge request. It does not mean merge or deployment
is authorized. The autonomous field is true for Autonomous and false for
Interactive. Choose the narrowest primaryAction that matches the required
next behavior.

publicationActor identifies the account that must perform an authorized
pull-request mutation: repository-defined when a
verified repository contract names another actor, current-session when the
active credential is the applicable default, or not-applicable when no remote
publication is authorized or pending.

workLimit states whether the next behavior puts a timeout, deadline, or time
budget on the request's long-running or unknown-duration work: no-limit,
time-limited, or not-applicable when there is no such work. hangTimeout states
whether an operation in the request that can hang gets a timeout: bounded,
unbounded, or not-applicable when there is no such operation. Classify each
independently.

The stop-and-report label means honoring an explicit user stop instruction.
The answer-read-only label means answering from evidence already in hand
without further inspection or edits; obtain-evidence-yourself means inspecting
accessible sources yourself before answering, acting, or asking.
The report-blocker label covers reporting a blocker when no independent
authorized work remains and no more specific primaryAction applies (for
example, autonomous-readiness-checkpoint or clarify-ownership).

blockerSource identifies the observed source of a blocker: none, repository,
skill, tool, access, or ambiguity. Do not infer a more specific cause than the
scenario establishes. When a rejection is reported, identify its original
source even if a permitted recovery is available; primaryAction independently
states what to do next.

closingQuestion states whether the turn ends by asking the user something:
none, required-confirmation for a confirmation the active instructions require
before the next step, material-decision for a choice between materially
different work that blocks authorized work, or next-step for asking whether or
how to continue with the results.

Request:
$($Case.prompt)
"@
}

function Read-AgentResponse {
    param(
        [Parameter(Mandatory)][string]$AgentTarget,
        [Parameter(Mandatory)]$Case,
        [Parameter(Mandatory)][string]$CaseOutputRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($ResponseDirectory)) {
        $responsePath = Join-Path (Join-Path $ResponseDirectory $AgentTarget) ($Case.id + '.json')
        if (-not (Test-Path -LiteralPath $responsePath -PathType Leaf)) {
            throw "Missing supplied response for $AgentTarget/$($Case.id): $responsePath"
        }
        return (Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json)
    }

    $workspace = Join-Path $CaseOutputRoot 'workspace'
    $null = New-Item -ItemType Directory -Path $workspace -Force
    & git -C $workspace init --quiet
    if ($LASTEXITCODE -ne 0) { throw "Could not initialize evaluation workspace for $AgentTarget/$($Case.id)." }

    $instructionsPath = Join-Path $workspace $(if ($AgentTarget -eq 'codex') { 'AGENTS.md' } else { 'CLAUDE.md' })
    Write-CompiledInstructions -AgentTarget $AgentTarget -InstructionSet $Case.instructionSet -Destination $instructionsPath
    $prompt = Get-EvaluationPrompt -Case $Case
    $responsePath = Join-Path $CaseOutputRoot 'response.json'
    $prompt | Set-Content -LiteralPath (Join-Path $CaseOutputRoot 'prompt.txt')

    switch ($AgentTarget) {
        'codex' {
            if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
                throw 'Codex CLI is unavailable.'
            }
            $arguments = @(
                'exec', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--strict-config',
                '--sandbox', 'read-only', '--color', 'never', '--json', '--cd', $workspace,
                '--output-schema', $schemaPath, '--output-last-message', $responsePath
            )
            if ($CodexModel) { $arguments += @('--model', $CodexModel) }
            if ($CodexReasoningEffort) { $arguments += @('-c', ('model_reasoning_effort="' + $CodexReasoningEffort + '"')) }
            if ($CodexModelInstructionsFile) { $arguments += @('-c', ('model_instructions_file="' + ($CodexModelInstructionsFile -replace '\\', '/') + '"')) }
            $arguments += '-'
            # --ignore-rules disables execpolicy .rules files; AGENTS.md remains
            # the project instruction channel under evaluation.
            Invoke-EvaluationClient -Client codex -Arguments $arguments -Prompt $prompt -Workspace $workspace `
                -LogPath (Join-Path $CaseOutputRoot 'client.jsonl') -ErrorPath (Join-Path $CaseOutputRoot 'client.stderr.txt') `
                -MetadataPath (Join-Path $CaseOutputRoot 'client.metadata.json') -Model $CodexModel -Effort $CodexReasoningEffort
            return Read-EvaluationResponse $responsePath
        }
        'claude' {
            if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
                throw 'Claude CLI is unavailable.'
            }
            $arguments = @('--print', '--no-session-persistence', '--permission-mode', 'dontAsk',
                '--setting-sources', '', '--disable-slash-commands', '--tools', '',
                '--system-prompt-file', $instructionsPath, '--json-schema', $schema,
                '--output-format', 'stream-json', '--verbose')
            if ($ClaudeModel) { $arguments += @('--model', $ClaudeModel) }
            if ($ClaudeEffort) { $arguments += @('--effort', $ClaudeEffort) }
            $logPath = Join-Path $CaseOutputRoot 'client.jsonl'
            Invoke-EvaluationClient -Client claude -Arguments $arguments -Prompt $prompt -Workspace $workspace `
                -LogPath $logPath -ErrorPath (Join-Path $CaseOutputRoot 'client.stderr.txt') `
                -MetadataPath (Join-Path $CaseOutputRoot 'client.metadata.json') -Model $ClaudeModel -Effort $ClaudeEffort
            $value = Read-ClaudeEvaluationResponse $logPath
            $value | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $responsePath
            return $value
        }
    }
}

function Compare-ExpectedBehavior {
    param(
        [Parameter(Mandatory)][string]$AgentTarget,
        [Parameter(Mandatory)]$Case,
        [Parameter(Mandatory)]$Actual
    )

    $expectationProperty = $expectationDocument.expectations.PSObject.Properties[$Case.id]
    if (-not $expectationProperty) { throw "No expectation exists for case '$($Case.id)'." }
    $expected = $expectationProperty.Value
    $mismatches = [Collections.Generic.List[string]]::new()

    $actualProperties = @($Actual.PSObject.Properties)
    foreach ($requiredName in @($schemaDocument.required)) {
        if (-not $Actual.PSObject.Properties[$requiredName]) {
            $mismatches.Add("response is missing required '$requiredName'")
        }
    }
    foreach ($actualProperty in $actualProperties) {
        $contractProperty = $schemaDocument.properties.PSObject.Properties[$actualProperty.Name]
        if (-not $contractProperty) {
            $mismatches.Add("response contains unexpected '$($actualProperty.Name)'")
            continue
        }
        $contract = $contractProperty.Value
        $typeMatches = switch ($contract.type) {
            'string' { $actualProperty.Value -is [string] }
            'boolean' { $actualProperty.Value -is [bool] }
            default { $false }
        }
        if (-not $typeMatches) {
            $actualType = if ($null -eq $actualProperty.Value) { 'null' } else { $actualProperty.Value.GetType().Name }
            $mismatches.Add("$($actualProperty.Name) must be $($contract.type), got $actualType")
            continue
        }
        if ($contract.PSObject.Properties.Name -contains 'enum' -and
            $actualProperty.Value -cnotin @($contract.enum)) {
            $mismatches.Add("$($actualProperty.Name) has unsupported value '$($actualProperty.Value)'")
        }
    }

    foreach ($property in $expected.PSObject.Properties) {
        $actualProperty = $Actual.PSObject.Properties[$property.Name]
        if (-not $actualProperty) {
            $mismatches.Add("missing '$($property.Name)'")
            continue
        }
        # Enum expectations may list accepted alternatives; responses stay scalar.
        if ($property.Value -is [array]) {
            $contract = $schemaDocument.properties.PSObject.Properties[$property.Name].Value
            if (-not $contract -or $contract.type -ne 'string' -or
                $contract.PSObject.Properties.Name -notcontains 'enum' -or
                -not $property.Value.Count -or @($property.Value | Where-Object {
                    $_ -isnot [string] -or $_ -cnotin @($contract.enum)
                }).Count) {
                $mismatches.Add("$($property.Name): invalid enum alternatives")
            } elseif ($actualProperty.Value -isnot [string] -or $actualProperty.Value -cnotin $property.Value) {
                $mismatches.Add("$($property.Name): expected one of '$($property.Value -join ', ')', got '$($actualProperty.Value)'")
            }
            continue
        }
        if ($null -eq $actualProperty.Value) {
            $mismatches.Add("$($property.Name): expected type '$($property.Value.GetType().Name)', got 'null'")
        } elseif ($actualProperty.Value.GetType() -ne $property.Value.GetType()) {
            $mismatches.Add("$($property.Name): expected type '$($property.Value.GetType().Name)', got '$($actualProperty.Value.GetType().Name)'")
        } elseif (-not [object]::Equals($actualProperty.Value, $property.Value)) {
            $mismatches.Add("$($property.Name): expected '$($property.Value)', got '$($actualProperty.Value)'")
        }
    }
    return [pscustomobject]@{
        target = $AgentTarget
        case = $Case.id
        passed = $mismatches.Count -eq 0
        mismatches = @($mismatches)
        actual = $Actual
    }
}

$results = [Collections.Generic.List[object]]::new()
$configuration = @{codexInstructionBaseline = $baseline; suite = $Suite; targets = $requestedTargets; claudeModel = $ClaudeModel; claudeEffort = $ClaudeEffort; codexModel = $CodexModel; codexReasoningEffort = $CodexReasoningEffort}
$runStatus = 'interrupted'
try {
    foreach ($case in $selectedCases) {
        foreach ($agentTarget in @($case.targets | Where-Object { $_ -in $requestedTargets })) {
            $caseOutputRoot = Join-Path (Join-Path $resolvedOutputDirectory $agentTarget) $case.id
            $null = New-Item -ItemType Directory -Path $caseOutputRoot -Force
            $result = @{target = $agentTarget; case = $case.id; status = 'running'; passed = $false; failureKind = $null; mismatches = @()}
            $results.Add($result)
            Write-EvaluationSummary $resolvedOutputDirectory $results.ToArray() 'running' $configuration
            Write-Host "START $agentTarget/$($case.id)"
            try {
                $actual = Read-AgentResponse -AgentTarget $agentTarget -Case $case -CaseOutputRoot $caseOutputRoot
                if ($null -eq $actual) { throw 'Client returned an empty or null response.' }
                $score = Compare-ExpectedBehavior -AgentTarget $agentTarget -Case $case -Actual $actual
                $result.passed = $score.passed
                $result.mismatches = $score.mismatches
                $result.actual = $actual
                $result.failureKind = if ($score.passed) { 'none' } else { 'behavior' }
                $result.status = 'completed'
            } catch {
                $result.failureKind = 'execution'
                $result.mismatches = @($_.Exception.Message)
                $result.status = 'failed'
            }
            Write-EvaluationSummary $resolvedOutputDirectory $results.ToArray() 'running' $configuration
            $state = if ($result.passed) { 'PASS' } else { 'FAIL' }
            Write-Host "$state $agentTarget/$($case.id)"
            foreach ($mismatch in $result.mismatches) { Write-Host "  $mismatch" }
        }
    }
    $runStatus = 'completed'
} finally {
    Write-EvaluationSummary $resolvedOutputDirectory $results.ToArray() $runStatus $configuration
}
Get-Content -LiteralPath (Join-Path $resolvedOutputDirectory 'summary.json') -Raw
if (@($results | Where-Object { -not $_.passed }).Count) { exit 1 }
