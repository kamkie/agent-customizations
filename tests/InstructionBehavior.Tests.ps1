[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'
$cases = Get-Content -LiteralPath (Join-Path $fixtureRoot 'instruction-behavior-cases.json') -Raw | ConvertFrom-Json
$expectations = Get-Content -LiteralPath (Join-Path $fixtureRoot 'instruction-behavior-expectations.json') -Raw | ConvertFrom-Json
$schema = Get-Content -LiteralPath (Join-Path $fixtureRoot 'instruction-behavior-response.schema.json') -Raw | ConvertFrom-Json
$runner = Join-Path $repositoryRoot 'scripts\evaluate-instructions.ps1'

if ($cases.schemaVersion -ne 1 -or $expectations.schemaVersion -ne 1) {
    throw 'Instruction behavior fixtures must use schemaVersion 1.'
}
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw 'Instruction behavior evaluation runner is missing.'
}

$ids = @($cases.cases.id)
if ($ids.Count -eq 0 -or @($ids | Select-Object -Unique).Count -ne $ids.Count) {
    throw 'Instruction behavior cases must contain unique non-empty ids.'
}
$expectedIds = @($expectations.expectations.PSObject.Properties.Name)
if (@($ids | Where-Object { $_ -notin $expectedIds }).Count -gt 0 -or
    @($expectedIds | Where-Object { $_ -notin $ids }).Count -gt 0) {
    throw 'Instruction behavior cases and expectations must have exactly matching ids.'
}

$allowedTargets = @('codex', 'claude')
$allowedInstructionSets = @('global', 'campaign', 'review')
$knownProperties = @($schema.properties.PSObject.Properties.Name)
$answerLeakPattern = '(?im)(?:^\s*(?:expected|answer|rubric|solution)\b|\b(?:expected\s+(?:answer|outcome|behavior|result)|answer\s*:|rubric\s*:|solution\s*:))'
foreach ($sample in @(
    'Use the expected outcome: stop.',
    'The answer: continue.',
    'Internal rubric: choose careful.',
    'Solution: publish the branch.',
    'Solution should be to stop and ask.',
    'Rubric below — pick investigation.'
)) {
    if ($sample -notmatch $answerLeakPattern) {
        throw "Instruction behavior answer-leak guard missed sample: $sample"
    }
}
$allowedValues = @{}
foreach ($property in $schema.properties.PSObject.Properties) {
    if ($property.Value.PSObject.Properties.Name -contains 'enum') {
        $allowedValues[$property.Name] = @($property.Value.enum)
    }
}

foreach ($case in $cases.cases) {
    if ([string]::IsNullOrWhiteSpace([string]$case.prompt)) {
        throw "Instruction behavior case '$($case.id)' has no prompt."
    }
    if (@($case.targets).Count -eq 0 -or @($case.targets | Where-Object { $_ -notin $allowedTargets }).Count -gt 0) {
        throw "Instruction behavior case '$($case.id)' has invalid targets."
    }
    if ($case.instructionSet -notin $allowedInstructionSets) {
        throw "Instruction behavior case '$($case.id)' has an invalid instruction set."
    }
    if ($case.instructionSet -eq 'campaign' -and 'claude' -in @($case.targets)) {
        throw "Campaign behavior case '$($case.id)' cannot target Claude."
    }
    if ($case.prompt -match $answerLeakPattern) {
        throw "Instruction behavior case '$($case.id)' leaks its expectation into the prompt."
    }

    $expected = $expectations.expectations.PSObject.Properties[$case.id].Value
    $expectedProperties = @($expected.PSObject.Properties)
    if ($expectedProperties.Count -eq 0) { throw "Expectation '$($case.id)' is empty." }
    foreach ($property in $expectedProperties) {
        if ($property.Name -notin $knownProperties) {
            throw "Expectation '$($case.id)' contains unknown property '$($property.Name)'."
        }
        if ($allowedValues.ContainsKey($property.Name) -and $property.Value -notin $allowedValues[$property.Name]) {
            throw "Expectation '$($case.id)' has invalid '$($property.Name)' value '$($property.Value)'."
        }
    }
}

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$responseRoot = Join-Path $temporaryRoot ('instruction-behavior-contract-test-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($case in $cases.cases) {
        $expected = $expectations.expectations.PSObject.Properties[$case.id].Value
        foreach ($target in $case.targets) {
            $targetRoot = Join-Path $responseRoot $target
            $null = New-Item -ItemType Directory -Path $targetRoot -Force
            $response = [ordered]@{
                mode = 'standard'
                autonomous = $false
                primaryAction = 'answer-read-only'
                publicationAuthorized = $false
                mergeAuthorized = $false
                deploymentAuthorized = $false
                blockerSource = 'none'
            }
            foreach ($property in $expected.PSObject.Properties) {
                $response[$property.Name] = $property.Value
            }
            $response | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $targetRoot ($case.id + '.json')) -Encoding utf8
        }
    }

    $passOutput = @(& pwsh -NoProfile -File $runner -Target all -ResponseDirectory $responseRoot 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'The instruction behavior scorer rejected matching responses: ' + ($passOutput -join ' ')
    }

    $negativeCase = $cases.cases | Where-Object id -eq 'capability-question' | Select-Object -First 1
    if (-not $negativeCase) { throw 'The scorer negative controls require the capability-question case.' }
    $negativeExpectation = $expectations.expectations.PSObject.Properties[$negativeCase.id].Value
    $negativeTarget = $negativeCase.targets[0]
    $negativeResponse = Join-Path (Join-Path $responseRoot $negativeTarget) ($negativeCase.id + '.json')
    $mutated = Get-Content -LiteralPath $negativeResponse -Raw | ConvertFrom-Json
    $mutated.publicationAuthorized = [string]$negativeExpectation.publicationAuthorized
    $mutated | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $negativeResponse -Encoding utf8

    $failOutput = @(& pwsh -NoProfile -File $runner -Target $negativeTarget -CaseId $negativeCase.id -ResponseDirectory $responseRoot 2>&1)
    if ($LASTEXITCODE -eq 0) {
        throw 'The instruction behavior scorer accepted a deliberately incorrect response.'
    }
    if (($failOutput -join ' ') -notmatch 'publicationAuthorized must be boolean') {
        throw 'The instruction behavior scorer did not report the supplied response type violation.'
    }

    $mutated.publicationAuthorized = $negativeExpectation.publicationAuthorized
    $mutated.mode = $null
    $mutated | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $negativeResponse -Encoding utf8
    $nullOutput = @(& pwsh -NoProfile -File $runner -Target $negativeTarget -CaseId $negativeCase.id -ResponseDirectory $responseRoot 2>&1)
    if ($LASTEXITCODE -eq 0 -or ($nullOutput -join ' ') -notmatch 'mode must be string, got null') {
        throw 'The instruction behavior scorer did not report a null response value as a contract violation.'
    }

    $mutated.mode = $negativeExpectation.mode
    $wrongPublication = -not [bool]$negativeExpectation.publicationAuthorized
    $mutated.publicationAuthorized = $wrongPublication
    $mutated | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $negativeResponse -Encoding utf8
    $valueOutput = @(& pwsh -NoProfile -File $runner -Target $negativeTarget -CaseId $negativeCase.id -ResponseDirectory $responseRoot 2>&1)
    $valueMismatch = "publicationAuthorized: expected '$($negativeExpectation.publicationAuthorized)', got '$wrongPublication'"
    if ($LASTEXITCODE -eq 0 -or
        ($valueOutput -join ' ') -notmatch [regex]::Escape($valueMismatch)) {
        throw 'The instruction behavior scorer did not reject a correctly typed wrong value.'
    }
} finally {
    if (Test-Path -LiteralPath $responseRoot -PathType Container) {
        Remove-Item -LiteralPath $responseRoot -Recurse -Force
    }
}

Write-Host 'Instruction behavior evaluation contract tests: OK'
exit 0
