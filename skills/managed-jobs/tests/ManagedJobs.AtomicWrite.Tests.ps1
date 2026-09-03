[CmdletBinding()]
param()

# Regression test for the Windows replace race in Write-ManagedJob: several
# processes (controller start/status, the host, hooks) may replace or read one
# record at the same moment. Every writer must succeed, the record must always
# parse as one complete write, and no temporary files may be left behind.

$ErrorActionPreference = 'Stop'
$commonScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\ManagedJob.Common.ps1'
. $commonScript
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('managed-jobs-atomic-write-' + [guid]::NewGuid().ToString('N'))
$assertionCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:assertionCount++
}

$writerCount = 6
$readerCount = 2
$iterations = 60
$recordPath = Join-Path $testRoot 'jobs\20000101-000000-atomic-write-000001.json'

$writerScript = {
    param([string]$CommonScript, [string]$Path, [int]$Writer, [int]$Iterations, [Threading.ManualResetEventSlim]$Gate)
    $ErrorActionPreference = 'Stop'
    . $CommonScript
    $Gate.Wait()
    $failures = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Iterations; $i++) {
        try {
            Write-ManagedJob -Path $Path -Job ([ordered]@{
                schemaVersion = 4
                id = '20000101-000000-atomic-write-000001'
                status = 'running'
                writer = $Writer
                iteration = $i
                # Long enough that a torn or partially replaced file cannot parse.
                padding = ('x' * 4096)
            })
        } catch {
            $failures.Add("writer $Writer iteration $($i): $($_.Exception.Message)")
        }
    }
    return $failures
}

$readerScript = {
    param([string]$CommonScript, [string]$Path, [int]$Iterations, [Threading.ManualResetEventSlim]$Gate)
    $ErrorActionPreference = 'Stop'
    . $CommonScript
    $Gate.Wait()
    $failures = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Iterations; $i++) {
        try {
            $job = Read-ManagedJob -Path $Path
            if ($job.padding.Length -ne 4096) { $failures.Add("reader iteration $($i): torn record") }
        } catch {
            $failures.Add("reader iteration $($i): $($_.Exception.Message)")
        }
    }
    return $failures
}

$pool = $null
$handles = @()
try {
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $recordPath) -Force
    # Seed the record so readers and the first replace both hit an existing file.
    Write-ManagedJob -Path $recordPath -Job ([ordered]@{ schemaVersion = 4; id = 'seed'; status = 'starting'; padding = ('x' * 4096) })

    $gate = [Threading.ManualResetEventSlim]::new($false)
    $pool = [runspacefactory]::CreateRunspacePool(1, $writerCount + $readerCount)
    $pool.Open()
    for ($writer = 0; $writer -lt $writerCount; $writer++) {
        $shell = [powershell]::Create()
        $shell.RunspacePool = $pool
        $null = $shell.AddScript($writerScript).AddArgument($commonScript).AddArgument($recordPath).AddArgument($writer).AddArgument($iterations).AddArgument($gate)
        $handles += [pscustomobject]@{ shell = $shell; async = $shell.BeginInvoke() }
    }
    for ($reader = 0; $reader -lt $readerCount; $reader++) {
        $shell = [powershell]::Create()
        $shell.RunspacePool = $pool
        $null = $shell.AddScript($readerScript).AddArgument($commonScript).AddArgument($recordPath).AddArgument($iterations).AddArgument($gate)
        $handles += [pscustomobject]@{ shell = $shell; async = $shell.BeginInvoke() }
    }
    # Release every runspace at once so the replaces genuinely overlap.
    $gate.Set()

    $failures = [Collections.Generic.List[string]]::new()
    foreach ($handle in $handles) {
        try {
            foreach ($result in $handle.shell.EndInvoke($handle.async)) { $failures.AddRange([string[]]@($result)) }
        } catch {
            $failures.Add("runspace failed: $($_.Exception.Message)")
        }
        if ($handle.shell.HadErrors) {
            foreach ($record in $handle.shell.Streams.Error) { $failures.Add("runspace error: $record") }
        }
        $handle.shell.Dispose()
    }
    $handles = @()

    Assert-True ($failures.Count -eq 0) ("Concurrent record writers and readers must not fail:`n" + ($failures -join "`n"))

    $final = Read-ManagedJob -Path $recordPath
    Assert-True ($final.status -eq 'running' -and $final.padding.Length -eq 4096 -and $final.iteration -eq ($iterations - 1)) `
        'The final record should be one complete last write from some writer.'
    $leftovers = @(Get-ChildItem -LiteralPath (Split-Path -Parent $recordPath) -Force -File | Where-Object { $_.Name -ne (Split-Path -Leaf $recordPath) })
    Assert-True ($leftovers.Count -eq 0) ('Atomic writes must not leave temporary files behind: ' + (@($leftovers | ForEach-Object Name) -join ', '))

    [pscustomobject]@{
        writers = $writerCount
        readers = $readerCount
        iterations = $iterations
        assertions = $assertionCount
        result = 'Passed'
    } | ConvertTo-Json
} finally {
    foreach ($handle in $handles) { try { $handle.shell.Dispose() } catch {} }
    if ($pool) { $pool.Dispose() }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
