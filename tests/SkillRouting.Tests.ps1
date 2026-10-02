[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/AgentCustomization.Common.ps1')
$repositoryRoot = Get-CustomizationRepositoryRoot
$manifest = Get-CustomizationManifest
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'
$cases = Get-Content -LiteralPath (Join-Path $fixtureRoot 'skill-routing-cases.json') -Raw | ConvertFrom-Json
$expectations = Get-Content -LiteralPath (Join-Path $fixtureRoot 'skill-routing-expectations.json') -Raw | ConvertFrom-Json
$schema = Get-Content -LiteralPath (Join-Path $fixtureRoot 'skill-routing-response.schema.json') -Raw | ConvertFrom-Json
$runner = Join-Path $repositoryRoot 'scripts\evaluate-instructions.ps1'

if ($cases.schemaVersion -ne 1 -or $expectations.schemaVersion -ne 1) {
    throw 'Skill routing fixtures must use schemaVersion 1.'
}

$ids = @($cases.cases.id)
if ($ids.Count -eq 0 -or @($ids | Select-Object -Unique).Count -ne $ids.Count) {
    throw 'Skill routing cases must contain unique non-empty ids.'
}
$expectedIds = @($expectations.expectations.PSObject.Properties.Name)
if (@($ids | Where-Object { $_ -notin $expectedIds }).Count -gt 0 -or
    @($expectedIds | Where-Object { $_ -notin $ids }).Count -gt 0) {
    throw 'Skill routing cases and expectations must have exactly matching ids.'
}

$targetSkills = @{}
foreach ($targetName in @('codex', 'claude')) {
    $targetSkills[$targetName] = @($manifest.targets.$targetName.skills)
}
$allSkills = @($targetSkills.Values | ForEach-Object { $_ } | Sort-Object -Unique)
$schemaChoices = @($schema.properties.skill.enum)
$expectedChoices = (@($allSkills) + 'none' | Sort-Object) -join ','
$actualChoices = (@($schemaChoices) | Sort-Object) -join ','
if ($expectedChoices -ne $actualChoices) {
    throw 'The skill routing response schema must list every manifest skill plus none.'
}
if ((@($schema.required) -join ',') -ne 'skill' -or @($schema.properties.PSObject.Properties).Count -ne 1) {
    throw 'The skill routing response schema must require only the skill property.'
}

$answerLeakPattern = '(?im)(?:^\s*(?:expected|answer|rubric|solution)\b|\b(?:expected\s+(?:answer|outcome|behavior|result|skill)|answer\s*:|rubric\s*:|solution\s*:))'
$positiveCounts = @{}
$noneCounts = @{ codex = 0; claude = 0 }
foreach ($case in $cases.cases) {
    if ([string]::IsNullOrWhiteSpace([string]$case.prompt)) {
        throw "Skill routing case '$($case.id)' has no prompt."
    }
    if (@($case.targets).Count -eq 0 -or @($case.targets | Where-Object { $_ -notin @('codex', 'claude') }).Count -gt 0) {
        throw "Skill routing case '$($case.id)' has invalid targets."
    }
    if ($case.instructionSet -ne 'skill-catalog') {
        throw "Skill routing case '$($case.id)' must use the skill-catalog instruction set."
    }
    if ($case.prompt -match $answerLeakPattern) {
        throw "Skill routing case '$($case.id)' leaks its expectation into the prompt."
    }

    $expected = $expectations.expectations.PSObject.Properties[$case.id].Value
    if ((@($expected.PSObject.Properties.Name) -join ',') -ne 'skill' -or $expected.skill -notin $schemaChoices) {
        throw "Expectation '$($case.id)' must name exactly one schema skill choice."
    }
    if ($expected.skill -ne 'none' -and $case.prompt -match [regex]::Escape($expected.skill)) {
        throw "Skill routing case '$($case.id)' names its expected skill."
    }
    foreach ($target in $case.targets) {
        if ($expected.skill -eq 'none') {
            $noneCounts[$target]++
        } elseif ($expected.skill -notin $targetSkills[$target]) {
            throw "Skill routing case '$($case.id)' expects '$($expected.skill)', which is not deployed to $target."
        } else {
            $key = "$target/$($expected.skill)"
            $positiveCounts[$key] = 1 + [int]$positiveCounts[$key]
        }
    }
}
foreach ($target in $targetSkills.Keys) {
    foreach ($skill in $targetSkills[$target]) {
        if ([int]$positiveCounts["$target/$skill"] -lt 3) {
            throw "Skill '$skill' needs at least three routing cases for target $target."
        }
    }
    if ($noneCounts[$target] -lt 3) {
        throw "Target $target needs at least three no-skill routing cases."
    }
}

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$responseRoot = Join-Path $temporaryRoot ('skill-routing-contract-test-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($case in $cases.cases) {
        $expected = $expectations.expectations.PSObject.Properties[$case.id].Value
        foreach ($target in $case.targets) {
            $targetRoot = Join-Path $responseRoot $target
            $null = New-Item -ItemType Directory -Path $targetRoot -Force
            @{ skill = $expected.skill } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $targetRoot ($case.id + '.json')) -Encoding utf8
        }
    }

    $passOutput = @(& pwsh -NoProfile -File $runner -Suite skill-routing -Target all -ResponseDirectory $responseRoot 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'The skill routing scorer rejected matching responses: ' + ($passOutput -join ' ')
    }

    $negativeCase = $cases.cases | Where-Object id -eq 'none-simple-lookup' | Select-Object -First 1
    if (-not $negativeCase) { throw 'The scorer negative control requires the none-simple-lookup case.' }
    $negativeResponse = Join-Path (Join-Path $responseRoot 'claude') ($negativeCase.id + '.json')
    @{ skill = 'managed-jobs' } | ConvertTo-Json | Set-Content -LiteralPath $negativeResponse -Encoding utf8
    $failOutput = @(& pwsh -NoProfile -File $runner -Suite skill-routing -Target claude -CaseId $negativeCase.id -ResponseDirectory $responseRoot 2>&1)
    if ($LASTEXITCODE -eq 0 -or ($failOutput -join ' ') -notmatch [regex]::Escape("skill: expected 'none', got 'managed-jobs'")) {
        throw 'The skill routing scorer accepted a wrong skill choice.'
    }
} finally {
    if (Test-Path -LiteralPath $responseRoot -PathType Container) {
        Remove-Item -LiteralPath $responseRoot -Recurse -Force
    }
}

Write-Host "Skill routing evaluation contract tests: $($ids.Count) cases OK"
exit 0
