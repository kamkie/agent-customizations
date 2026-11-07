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
        if ($property.Value -is [array] -and
            (-not $allowedValues.ContainsKey($property.Name) -or -not $property.Value.Count)) {
            throw "Expectation '$($case.id)' requires nonempty enum alternatives."
        }
        if ($allowedValues.ContainsKey($property.Name) -and @($property.Value | Where-Object {
            $_ -isnot [string] -or $_ -cnotin $allowedValues[$property.Name]
        }).Count) {
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
                autonomous = $false
                primaryAction = 'answer-read-only'
                workLimit = 'not-applicable'
                hangTimeout = 'not-applicable'
                publicationAuthorized = $false
                publicationActor = 'not-applicable'
                mergeAuthorized = $false
                deploymentAuthorized = $false
                blockerSource = 'none'
                closingQuestion = 'none'
            }
            foreach ($property in $expected.PSObject.Properties) {
                $response[$property.Name] = if ($property.Value -is [array]) { $property.Value[0] } else { $property.Value }
            }
            $response | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $targetRoot ($case.id + '.json')) -Encoding utf8
        }
    }

    $passOutput = @(& pwsh -NoProfile -File $runner -Target all -ResponseDirectory $responseRoot -OutputDirectory (Join-Path $responseRoot "runs") 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'The instruction behavior scorer rejected matching responses: ' + ($passOutput -join ' ')
    }

    $monitoringResponse = Join-Path $responseRoot 'codex/delivery-quiet-progressing-job.json'
    $monitoring = Get-Content -LiteralPath $monitoringResponse -Raw | ConvertFrom-Json
    $monitoring.primaryAction = 'refresh-live-state'
    $monitoring | ConvertTo-Json | Set-Content -LiteralPath $monitoringResponse
    $alternativeOutput = @(& pwsh -NoProfile -File $runner -Target codex -CaseId delivery-quiet-progressing-job -ResponseDirectory $responseRoot -OutputDirectory (Join-Path $responseRoot "runs") 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'The scorer rejected an allowed monitoring alternative.' }
    $monitoring.primaryAction = 'cancel-hung-job-and-wait'
    $monitoring | ConvertTo-Json | Set-Content -LiteralPath $monitoringResponse
    $cancelOutput = @(& pwsh -NoProfile -File $runner -Target codex -CaseId delivery-quiet-progressing-job -ResponseDirectory $responseRoot -OutputDirectory (Join-Path $responseRoot "runs") 2>&1)
    if ($LASTEXITCODE -eq 0 -or ($cancelOutput -join ' ') -notmatch 'expected one of') {
        throw 'The scorer accepted cancellation of a progressing job.'
    }
    $monitoring.primaryAction = @('continue-authorized-work', 'refresh-live-state')
    $monitoring | ConvertTo-Json | Set-Content -LiteralPath $monitoringResponse
    $arrayOutput = @(& pwsh -NoProfile -File $runner -Target codex -CaseId delivery-quiet-progressing-job -ResponseDirectory $responseRoot -OutputDirectory (Join-Path $responseRoot "runs") 2>&1)
    if ($LASTEXITCODE -eq 0 -or ($arrayOutput -join ' ') -notmatch 'primaryAction must be string') {
        throw 'The scorer accepted an array instead of a scalar response.'
    }

    $closingResponse = Join-Path $responseRoot 'claude/readonly-summary-next-step.json'
    $closing = Get-Content -LiteralPath $closingResponse -Raw | ConvertFrom-Json
    $closing.closingQuestion = 'next-step'
    $closing | ConvertTo-Json | Set-Content -LiteralPath $closingResponse
    $closingOutput = @(& pwsh -NoProfile -File $runner -Target claude -CaseId readonly-summary-next-step -ResponseDirectory $responseRoot -OutputDirectory (Join-Path $responseRoot "runs") 2>&1)
    if ($LASTEXITCODE -eq 0 -or ($closingOutput -join ' ') -notmatch "closingQuestion: expected 'none', got 'next-step'") {
        throw 'The scorer accepted a closing next-step question after a finished read-only answer.'
    }

    $investigateResponse = Join-Path $responseRoot 'claude/investigate-option-question.json'
    $investigate = Get-Content -LiteralPath $investigateResponse -Raw | ConvertFrom-Json
    $investigate.primaryAction = 'answer-read-only'
    $investigate | ConvertTo-Json | Set-Content -LiteralPath $investigateResponse
    $investigateOutput = @(& pwsh -NoProfile -File $runner -Target claude -CaseId investigate-option-question -ResponseDirectory $responseRoot -OutputDirectory (Join-Path $responseRoot "runs") 2>&1)
    if ($LASTEXITCODE -eq 0 -or ($investigateOutput -join ' ') -notmatch 'primaryAction: expected one of') {
        throw 'The scorer accepted an answer that skips available investigation.'
    }

    $negativeCase = $cases.cases | Where-Object id -eq 'capability-question' | Select-Object -First 1
    if (-not $negativeCase) { throw 'The scorer negative controls require the capability-question case.' }
    $negativeExpectation = $expectations.expectations.PSObject.Properties[$negativeCase.id].Value
    $negativeTarget = $negativeCase.targets[0]
    $negativeResponse = Join-Path (Join-Path $responseRoot $negativeTarget) ($negativeCase.id + '.json')
    $mutated = Get-Content -LiteralPath $negativeResponse -Raw | ConvertFrom-Json
    $mutated.publicationAuthorized = [string]$negativeExpectation.publicationAuthorized
    $mutated | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $negativeResponse -Encoding utf8

    $failOutput = @(& pwsh -NoProfile -File $runner -Target $negativeTarget -CaseId $negativeCase.id -ResponseDirectory $responseRoot -OutputDirectory (Join-Path $responseRoot "runs") 2>&1)
    if ($LASTEXITCODE -eq 0) {
        throw 'The instruction behavior scorer accepted a deliberately incorrect response.'
    }
    if (($failOutput -join ' ') -notmatch 'publicationAuthorized must be boolean') {
        throw 'The instruction behavior scorer did not report the supplied response type violation.'
    }

    $mutated.publicationAuthorized = $negativeExpectation.publicationAuthorized
    $mutated.autonomous = $null
    $mutated | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $negativeResponse -Encoding utf8
    $nullOutput = @(& pwsh -NoProfile -File $runner -Target $negativeTarget -CaseId $negativeCase.id -ResponseDirectory $responseRoot -OutputDirectory (Join-Path $responseRoot "runs") 2>&1)
    if ($LASTEXITCODE -eq 0 -or ($nullOutput -join ' ') -notmatch 'autonomous must be boolean, got null') {
        throw 'The instruction behavior scorer did not report a null response value as a contract violation.'
    }

    $mutated.autonomous = $negativeExpectation.autonomous
    $wrongPublication = -not [bool]$negativeExpectation.publicationAuthorized
    $mutated.publicationAuthorized = $wrongPublication
    $mutated | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $negativeResponse -Encoding utf8
    $valueOutput = @(& pwsh -NoProfile -File $runner -Target $negativeTarget -CaseId $negativeCase.id -ResponseDirectory $responseRoot -OutputDirectory (Join-Path $responseRoot "runs") 2>&1)
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

# Native process checks share the production transport used by both evaluators.
. (Join-Path $repositoryRoot 'scripts/InstructionEvaluation.Common.ps1')
$nativeRoot = Join-Path $temporaryRoot ('evaluation-native-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $nativeRoot
$savedPath = $env:PATH
try {
    $pwsh = (Get-Command pwsh).Source
    $interrupted = @{status = 'running'; passed = $false; failureKind = $null; mismatches = @()}
    Write-EvaluationSummary $nativeRoot @($interrupted) 'interrupted' @{}
    $interruptedSummary = Get-Content (Join-Path $nativeRoot 'summary.json') -Raw | ConvertFrom-Json
    if ($interruptedSummary.failed -ne 1 -or $interruptedSummary.results[0].failureKind -ne 'interrupted' -or
        $interruptedSummary.results[0].status -ne 'interrupted' -or -not $interruptedSummary.results[0].mismatches.Count) { throw 'Interrupted case was not terminalized with a reason.' }
    $bin = Join-Path $nativeRoot 'bin'
    $null = New-Item -ItemType Directory $bin
    @'
$prompt = [Console]::In.ReadToEnd()
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'stdin.txt'), $prompt)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'argv.json'), ($args | ConvertTo-Json))
[Console]::Out.WriteLine('{"type":"system","model":"observed-model"}')
[Console]::Out.Flush()
[Console]::Error.WriteLine('synthetic diagnostic')
if (Test-Path (Join-Path $PSScriptRoot 'gate-enabled')) {
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'started'), [string]$PID)
    while (-not (Test-Path (Join-Path $PSScriptRoot 'released'))) { Start-Sleep -Milliseconds 20 }
}
[Console]::Out.WriteLine([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'envelope')))
exit ([int](Get-Content (Join-Path $PSScriptRoot 'exit')))
'@ | Set-Content (Join-Path $bin 'client.ps1')
    $shim = '$input | & pwsh -NoProfile -File (Join-Path $PSScriptRoot "client.ps1") @args; exit $LASTEXITCODE'
    if ($IsWindows) { $shim | Set-Content (Join-Path $bin 'claude.ps1') }
    else {
        "#!/usr/bin/env pwsh`n$shim" | Set-Content (Join-Path $bin 'claude')
        & chmod +x (Join-Path $bin 'claude')
    }
    $env:PATH = $bin + [IO.Path]::PathSeparator + $savedPath
    $outputRoot = Join-Path $nativeRoot 'runs'
    foreach ($filter in @(',', ' ', 'unknown-synthetic-case')) {
        $output = @(& $pwsh -NoProfile -File $runner -Target claude -CaseId $filter -OutputDirectory $outputRoot 2>&1)
        if ($LASTEXITCODE -eq 0 -or (Test-Path $outputRoot) -or (Test-Path (Join-Path $bin 'argv.json'))) { throw 'Invalid classification filter launched a client or created artifacts.' }
    }
    $env:PATH = ''
    $output = @(& $pwsh -NoProfile -File $runner -Target claude -CaseId capability-question -OutputDirectory $outputRoot 2>&1)
    if ($LASTEXITCODE -eq 0 -or (Test-Path $outputRoot)) { throw 'Missing client did not fail preflight.' }
    $env:PATH = $bin + [IO.Path]::PathSeparator + $savedPath
    $samples = @(
        @('null','execution',0), @('not JSON','execution',0),
        @('{"type":"result","subtype":"success"}','execution',0),
        @('{"type":"result","subtype":"success","result":""}','execution',0),
        @('{"type":"result","subtype":"success","result":"null"}','execution',0),
        @('{"type":"result","subtype":"error_during_execution","is_error":true,"structured_output":{}}','execution',0),
        @('{"type":"result","subtype":"success","structured_output":{}}','behavior',0),
        @('{"type":"result","subtype":"success","structured_output":{}}','execution',17)
    )
    $count = 0
    foreach ($sample in $samples) {
        $sample[0] | Set-Content (Join-Path $bin 'envelope')
        $sample[2] | Set-Content (Join-Path $bin 'exit')
        $output = @(& $pwsh -NoProfile -File $runner -Target claude -CaseId capability-question -ClaudeModel requested-model -OutputDirectory $outputRoot 2>&1)
        if ($LASTEXITCODE -eq 0) { throw 'Invalid or incomplete response passed.' }
        $runs = @(Get-ChildItem $outputRoot -Directory)
        $count++
        if ($runs.Count -ne $count) { throw 'A repeated run overwrote evidence.' }
        $run = ($runs | Sort-Object CreationTimeUtc | Select-Object -Last 1).FullName
        $summary = Get-Content (Join-Path $run 'summary.json') -Raw | ConvertFrom-Json
        if ($summary.results[0].failureKind -ne $sample[1]) { throw "Wrong envelope failure kind: $($summary | ConvertTo-Json -Depth 8)" }
        $caseRoot = Join-Path $run 'claude/capability-question'
        $metadata = Get-Content (Join-Path $caseRoot 'client.metadata.json') -Raw | ConvertFrom-Json
        if ($metadata.requestedModel -ne 'requested-model' -or $metadata.effectiveModels -notcontains 'observed-model') { throw 'Requested/observed identity was lost.' }
        if ((Get-Content (Join-Path $caseRoot 'client.stderr.txt') -Raw) -notmatch 'synthetic diagnostic') { throw 'Native stderr was lost.' }
        if ((Get-Content (Join-Path $caseRoot 'client.jsonl') -Raw) -notmatch [regex]::Escape($sample[0])) { throw 'Native envelope was lost.' }
        $argv = @(Get-Content (Join-Path $bin 'argv.json') -Raw | ConvertFrom-Json)
        if ($argv -notcontains 'requested-model' -or $argv -contains (Get-Content (Join-Path $bin 'stdin.txt') -Raw)) { throw 'Model argv or stdin prompt transport failed.' }
    }
    0 | Set-Content (Join-Path $bin 'exit')
    $largePrompt = ('Synthetic Unicode Ω 漢字 "quotes" $literal `backtick`' + "`n") * 1600 + 'end'
    Invoke-EvaluationClient -Client claude -Arguments @('--model','requested-model') -Prompt $largePrompt -Workspace $nativeRoot `
        -LogPath (Join-Path $nativeRoot 'large.jsonl') -ErrorPath (Join-Path $nativeRoot 'large.stderr.txt') `
        -MetadataPath (Join-Path $nativeRoot 'large.metadata.json') -Model requested-model
    $captured = [IO.File]::ReadAllText((Join-Path $bin 'stdin.txt'))
    if ($captured -cne ($largePrompt + [Environment]::NewLine)) { throw 'Large Unicode stdin prompt changed (apart from the documented pipeline newline).' }
    $argv = @(Get-Content (Join-Path $bin 'argv.json') -Raw | ConvertFrom-Json)
    if ($argv.Count -ne 2 -or $argv[1] -ne 'requested-model') { throw 'Large prompt appeared in native argv.' }
    Push-Location $nativeRoot
    try {
        $relative = New-EvaluationRunDirectory relative
        if (-not $relative.StartsWith((Join-Path $nativeRoot 'relative'))) { throw 'Output ignored PowerShell location.' }
    } finally { Pop-Location }
    $output = @(& $pwsh -NoProfile -File $runner -Target claude -CaseId capability-question 2>&1)
    $automaticRun = ([string]($output | Where-Object { [string]$_ -like 'Artifacts: *' } | Select-Object -First 1)).Substring(11)
    if (-not (Test-Path (Join-Path $automaticRun 'summary.json'))) { throw 'Automatic failed evidence was deleted.' }
    $prefix = (Join-Path ([IO.Path]::GetTempPath()) 'instruction-evaluations') + [IO.Path]::DirectorySeparatorChar
    if (-not ([IO.Path]::GetFullPath($automaticRun)).StartsWith($prefix)) { throw 'Unsafe automatic test cleanup.' }
    Get-ChildItem -LiteralPath $automaticRun -Recurse -Force | ForEach-Object { $_.Attributes = $_.Attributes -band (-bnot ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::ReadOnly)) }
    Remove-Item -LiteralPath $automaticRun -Recurse

    0 | Set-Content (Join-Path $bin 'exit')
    New-Item -ItemType File (Join-Path $bin 'gate-enabled') | Out-Null
    $driver = Join-Path $nativeRoot 'driver.ps1'
    @'
param($Runner, $Output, $Log)
& $Runner -Target claude -CaseId capability-question -OutputDirectory $Output *> $Log
exit $LASTEXITCODE
'@ | Set-Content $driver
    $gateRoot = Join-Path $nativeRoot 'gate-run'
    $driverLog = Join-Path $nativeRoot 'driver.log'
    $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile','-File',$driver,$runner,$gateRoot,$driverLog)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(30) # bounded native readiness probe
        do {
            if ($process.HasExited) { throw 'Gate process exited before readiness.' }
            $logs = @(Get-ChildItem $gateRoot -Filter client.jsonl -Recurse -ErrorAction SilentlyContinue)
            if ($logs.Count -eq 1 -and (Get-Content $logs[0].FullName -Raw) -match 'observed-model' -and (Test-Path (Join-Path $bin 'started'))) { break }
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Native gate readiness failed.' }
            Start-Sleep -Milliseconds 20
        } while ($true)
        if ((Get-Content $driverLog -Raw) -notmatch 'START claude/capability-question') { throw 'START was buffered.' }
        $summaryPath = Join-Path $logs[0].Directory.Parent.Parent.FullName 'summary.json'
        $pending = Get-Content $summaryPath -Raw | ConvertFrom-Json
        if ($pending.status -ne 'running' -or $pending.results[0].status -ne 'running') { throw 'Running process was marked complete.' }
        $nativePid = [int](Get-Content (Join-Path $bin 'started'))
        $reader = if ($IsWindows) { [IO.File]::Open($summaryPath, 'Open', 'Read', 'ReadWrite') } else { $null }
        try {
            New-Item -ItemType File (Join-Path $bin 'released') | Out-Null
            if ($reader) {
                # Let the runner reach atomic replacement while a normal reader
                # holds the destination without FILE_SHARE_DELETE.
                $replaceReady = [DateTime]::UtcNow.AddSeconds(5)
                while (-not (Test-Path (Join-Path (Split-Path $summaryPath) 'summary.tmp'))) {
                    if ($process.HasExited -or [DateTime]::UtcNow -gt $replaceReady) { throw 'Summary writer did not reach its replacement gate.' }
                    Start-Sleep -Milliseconds 20
                }
                if ($process.HasExited) { throw 'A monitoring reader aborted the run.' }
            }
        } finally { if ($reader) { $reader.Dispose() } }
        $process.WaitForExit()
        if (Get-Process -Id $nativePid -ErrorAction SilentlyContinue) { throw 'Native child survived completion.' }
        $final = Get-Content $summaryPath -Raw | ConvertFrom-Json
        if ($final.status -ne 'completed' -or $final.results[0].failureKind -ne 'behavior') { throw 'Gate completion lost final result.' }
    } finally {
        if (-not (Test-Path (Join-Path $bin 'released'))) { New-Item -ItemType File (Join-Path $bin 'released') | Out-Null }
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
} finally {
    $env:PATH = $savedPath
    if (-not ([IO.Path]::GetFullPath($nativeRoot)).StartsWith($temporaryRoot)) { throw 'Unsafe native test cleanup.' }
    Get-ChildItem -LiteralPath $nativeRoot -Recurse -Force | ForEach-Object { $_.Attributes = $_.Attributes -band (-bnot ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::ReadOnly)) }
    Remove-Item -LiteralPath $nativeRoot -Recurse
}
Write-Host 'Instruction behavior evaluation contract tests: OK'
exit 0
