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
$allowedInstructionSets = @('global', 'campaign')
$knownProperties = @($schema.properties.PSObject.Properties.Name)
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
    if ($case.prompt -match '(?im)^\s*(?:expected|answer|rubric|solution)\b') {
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
                mode = 'careful'
                primaryAction = 'answer-read-only'
                publicationAuthorized = $false
                mergeAuthorized = $false
                deploymentAuthorized = $false
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

    $firstCase = $cases.cases[0]
    $firstTarget = $firstCase.targets[0]
    $firstResponse = Join-Path (Join-Path $responseRoot $firstTarget) ($firstCase.id + '.json')
    $mutated = Get-Content -LiteralPath $firstResponse -Raw | ConvertFrom-Json
    $mutated.publicationAuthorized = 'false'
    $mutated | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $firstResponse -Encoding utf8

    $failOutput = @(& pwsh -NoProfile -File $runner -Target $firstTarget -CaseId $firstCase.id -ResponseDirectory $responseRoot 2>&1)
    if ($LASTEXITCODE -eq 0) {
        throw 'The instruction behavior scorer accepted a deliberately incorrect response.'
    }
    if (($failOutput -join ' ') -notmatch 'publicationAuthorized must be boolean') {
        throw 'The instruction behavior scorer did not report the supplied response type violation.'
    }
} finally {
    if (Test-Path -LiteralPath $responseRoot -PathType Container) {
        Remove-Item -LiteralPath $responseRoot -Recurse -Force
    }
}

Write-Host 'Instruction behavior evaluation contract tests: OK'
exit 0
