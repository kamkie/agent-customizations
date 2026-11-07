# Shared evidence transport for the classification and controlled-action evaluators.
function Get-EvaluationProperty {
    param($Value, [string]$Name)
    if ($null -ne $Value -and $Value.PSObject.Properties[$Name]) { return $Value.PSObject.Properties[$Name].Value }
    return $null
}

function New-EvaluationRunDirectory {
    param([string]$OutputDirectory)
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) 'instruction-evaluations' }
    $provider = $null; $drive = $null
    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw 'Evaluation output must use the filesystem provider.' }
    $run = Join-Path $root ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $run -Force
    Write-Host "Artifacts: $run"
    return $run
}

function Invoke-EvaluationClient {
    param([string]$Client, [string[]]$Arguments, [string]$Prompt, [string]$Workspace,
        [string]$LogPath, [string]$ErrorPath, [string]$MetadataPath,
        [AllowEmptyString()][string]$Model, [AllowEmptyString()][string]$Effort)
    $PSNativeCommandUseErrorActionPreference = $false
    $metadata = [ordered]@{client = $Client; requestedModel = $Model; requestedEffort = $Effort; effectiveModels = @(); status = 'running'; exitCode = $null; startedAt = [DateTime]::UtcNow.ToString('o'); completedAt = $null; stdoutLines = 0; stderrLines = 0}
    $metadata | ConvertTo-Json | Set-Content -LiteralPath $MetadataPath
    [IO.File]::WriteAllText($LogPath, '')
    [IO.File]::WriteAllText($ErrorPath, '')
    Write-Host "START native $Client; evidence: $MetadataPath"
    Push-Location $Workspace
    try {
        # Pipeline input avoids native command-line limits. Flush each received
        # record to disk before reporting it; START alone is not native progress.
        # Native launchers (including the Codex PowerShell shim) update this
        # automatic variable globally; a local shadow would hide their failure.
        $global:LASTEXITCODE = 0
        $Prompt | & $Client @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.ErrorRecord]) {
                [IO.File]::AppendAllText($ErrorPath, ([string]$_ + [Environment]::NewLine))
                $metadata.stderrLines++
            } else {
                [IO.File]::AppendAllText($LogPath, ([string]$_ + [Environment]::NewLine))
                $metadata.stdoutLines++
            }
            Write-Host ([string]$_)
        }
        $metadata.exitCode = $LASTEXITCODE
        $metadata.status = if ($LASTEXITCODE -eq 0) { 'completed' } else { 'failed' }
    } finally {
        Pop-Location
        if ($metadata.status -eq 'running') { $metadata.status = 'interrupted' }
        # Use only observed native model metadata, never the requested alias.
        $models = foreach ($line in [IO.File]::ReadLines($LogPath)) {
            try {
                $event = $line | ConvertFrom-Json -ErrorAction Stop
                $model = Get-EvaluationProperty $event 'model'
                if ($model) { [string]$model }
                $messageModel = Get-EvaluationProperty (Get-EvaluationProperty $event 'message') 'model'
                if ($messageModel) { [string]$messageModel }
                $usage = Get-EvaluationProperty $event 'modelUsage'
                if ($usage) { $usage.PSObject.Properties.Name }
            } catch { }
        }
        $metadata.effectiveModels = @($models | Sort-Object -Unique)
        $metadata.completedAt = [DateTime]::UtcNow.ToString('o')
        $metadata | ConvertTo-Json | Set-Content -LiteralPath $MetadataPath
        Write-Host "END native ${Client}: $($metadata.status); stdout records: $($metadata.stdoutLines); stderr records: $($metadata.stderrLines)"
    }
    if ($metadata.exitCode -ne 0) { throw "$Client client failed with exit $($metadata.exitCode); stdout: $LogPath; stderr: $ErrorPath; metadata: $MetadataPath" }
}

function Read-EvaluationResponse {
    param([string]$Path)
    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $value) { throw 'Client returned an empty or null response.' }
    return $value
}

function Read-ClaudeEvaluationResponse {
    param([string]$Path)
    $events = @(Get-Content -LiteralPath $Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
    if (-not $events.Count -or $null -in $events) { throw 'Claude returned an empty or null envelope.' }
    $results = @($events | Where-Object { (Get-EvaluationProperty $_ 'type') -eq 'result' })
    if ($results.Count -ne 1) { throw 'Claude returned no unique terminal result envelope.' }
    $envelope = $results[0]
    if ((Get-EvaluationProperty $envelope 'is_error') -eq $true -or (Get-EvaluationProperty $envelope 'subtype') -ne 'success') { throw 'Claude returned an unsuccessful result envelope.' }
    $structured = Get-EvaluationProperty $envelope 'structured_output'
    if ($null -ne $structured) { return $structured }
    if (-not $envelope.PSObject.Properties['result'] -or [string]::IsNullOrWhiteSpace([string]$envelope.result)) { throw 'Claude returned no structured result.' }
    $value = [string]$envelope.result | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $value) { throw 'Claude returned a null result.' }
    return $value
}

function Write-EvaluationSummary {
    param([string]$RunRoot, [object[]]$Results, [string]$Status, [hashtable]$Configuration)
    $summary = [ordered]@{status = $Status; artifacts = $RunRoot; configuration = $Configuration; cases = $Results.Count; passed = @($Results | Where-Object passed).Count; failed = @($Results | Where-Object { $_.status -ne 'running' -and -not $_.passed }).Count; results = @($Results)}
    # Readers always see a complete JSON document, even while a run is active.
    $temporary = Join-Path $RunRoot 'summary.tmp'
    $summary | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $temporary
    [IO.File]::Move($temporary, (Join-Path $RunRoot 'summary.json'), $true)
}
