[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helper = Join-Path $PSScriptRoot '..\scripts\Send-SecretFromDialog.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('store-secret-from-dialog-tests-' + [guid]::NewGuid().ToString('N'))
# The fake receiver runs in pwsh, a native executable like a real CLI.
$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$receiver = Join-Path $testRoot 'receiver.ps1'
$oldRoot = $env:FAKE_RECEIVER_ROOT
$assertions = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:assertions++
}

function New-Secure([string]$Value) {
    $secure = [Security.SecureString]::new()
    foreach ($character in $Value.ToCharArray()) { $secure.AppendChar($character) }
    $secure
}

# Builds ArgumentsJson for the fake receiver followed by the given arguments.
function Get-ReceiverArguments([string[]]$Arguments = @()) {
    ConvertTo-Json -Compress -InputObject @(@('-NoProfile', '-File', $receiver) + $Arguments)
}

function Reset-Receiver([string]$Mode = 'ok') {
    Get-ChildItem -LiteralPath $testRoot -Filter '*.txt' | Remove-Item
    Set-Content -LiteralPath (Join-Path $testRoot 'mode.cfg') -Value $Mode
}

function Invoke-Helper([hashtable]$Parameters) {
    $arguments = @{ Title = 'Test secret'; Executable = $pwsh; ArgumentsJson = (Get-ReceiverArguments) }
    foreach ($key in $Parameters.Keys) { $arguments[$key] = $Parameters[$key] }
    try {
        $output = & $helper @arguments 6>$null | Out-String
        [pscustomobject]@{ Output = $output; Error = $null }
    } catch {
        [pscustomobject]@{ Output = ''; Error = $_.Exception.Message }
    }
}

# Runs the helper as its own process and returns both streams together, as a managed-job log holds them.
function Invoke-HelperProcess([string]$Secret) {
    $command = "& '$helper' -Title 'Test secret' -Executable '$pwsh' -ArgumentsJson '$(Get-ReceiverArguments)' " +
        "-FieldValue @{ secret = (ConvertTo-SecureString '$Secret' -AsPlainText -Force) }"
    $output = & pwsh -NoProfile -Command $command 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Log = $output }
}

$null = New-Item -ItemType Directory -Path $testRoot
@'
$root = $env:FAKE_RECEIVER_ROOT
Set-Content -LiteralPath (Join-Path $root 'argv.txt') -Value ($args -join '|')
$stdin = [Console]::In.ReadToEnd()
[IO.File]::WriteAllText((Join-Path $root 'stdin.txt'), $stdin)
switch ((Get-Content -LiteralPath (Join-Path $root 'mode.cfg') -Raw).Trim()) {
    'fail-echo' { [Console]::Error.WriteLine("rejected: $stdin"); exit 3 }
    'linger' {
        # A descendant that inherits the output pipes and outlives the receiver.
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($a in @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60')) { $start.ArgumentList.Add($a) }
        $start.UseShellExecute = $false
        $child = [Diagnostics.Process]::Start($start)
        Set-Content -LiteralPath (Join-Path $root 'linger-pid.txt') -Value $child.Id
        exit 0
    }
    default { "stored: $stdin"; [Console]::Error.WriteLine("note: $stdin"); exit 0 }
}
'@ | Set-Content -LiteralPath $receiver

try {
    $env:FAKE_RECEIVER_ROOT = $testRoot

    Reset-Receiver
    $result = Invoke-Helper @{
        ArgumentsJson = Get-ReceiverArguments @('secret', 'set', 'API_KEY', '--repo', 'owner/name with space', '%PATH%', 'a&b')
        FieldValue = @{ secret = (New-Secure 'S3cret-value') }
    }
    Assert-True ($null -eq $result.Error) "Sending a single value failed: $($result.Error)"
    Assert-True (($result.Output | ConvertFrom-Json).exitCode -eq 0) 'The helper did not report success.'
    Assert-True ($result.Output -notmatch 'S3cret-value') 'The helper printed the value.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $testRoot 'stdin.txt')) -ceq 'S3cret-value') 'stdin did not hold exactly the raw value.'
    $argv = Get-Content -LiteralPath (Join-Path $testRoot 'argv.txt') -Raw
    Assert-True ($argv.Trim() -ceq 'secret|set|API_KEY|--repo|owner/name with space|%PATH%|a&b') "Arguments were not passed intact: $argv"

    Reset-Receiver
    $result = Invoke-Helper @{
        TextField = 'username'
        ConcealedField = 'password,otp-seed'
        StdinFormat = 'Json'
        FieldValue = @{ username = (New-Secure 'svc'); password = (New-Secure 'p@ss'); 'otp-seed' = (New-Secure 'seed') }
    }
    Assert-True ($null -eq $result.Error) "Sending JSON failed: $($result.Error)"
    $sent = [IO.File]::ReadAllText((Join-Path $testRoot 'stdin.txt')) | ConvertFrom-Json
    Assert-True ($sent.username -ceq 'svc' -and $sent.password -ceq 'p@ss' -and $sent.'otp-seed' -ceq 'seed') 'JSON stdin was wrong.'

    Reset-Receiver -Mode 'fail-echo'
    $run = Invoke-HelperProcess -Secret 'Synthetic-Echo-1'
    Assert-True ($run.ExitCode -ne 0) 'A failed command did not fail the helper.'
    Assert-True ($run.Log -match 'did not report success \(exit code 3\)') "A failed command was not reported: $($run.Log)"
    Assert-True ($run.Log -match '(?m)^Sending the secret to pwsh(\.exe)?\.') 'The pre-send line is missing.'
    Assert-True ($run.Log -notmatch 'Synthetic-Echo-1') 'The command output leaked the value into the helper streams.'

    Reset-Receiver
    $run = Invoke-HelperProcess -Secret 'Synthetic-Echo-2'
    Assert-True ($run.ExitCode -eq 0 -and $run.Log -notmatch 'Synthetic-Echo-2') 'A successful command leaked the value into the helper streams.'

    Reset-Receiver -Mode 'linger'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-Helper @{ FieldValue = @{ secret = (New-Secure 'x') } }
    $clock.Stop()
    $lingerPid = Get-Content -LiteralPath (Join-Path $testRoot 'linger-pid.txt') -ErrorAction SilentlyContinue
    if ($lingerPid) { Stop-Process -Id ([int]$lingerPid) -ErrorAction SilentlyContinue }
    Assert-True ($null -eq $result.Error -and $clock.Elapsed.TotalSeconds -lt 30) "A descendant holding the output pipes stalled the helper: $($clock.Elapsed.TotalSeconds)s $($result.Error)"

    Reset-Receiver
    $result = Invoke-Helper @{ FieldValue = @{ secret = [Security.SecureString]::new() } }
    Assert-True ($result.Error -match 'No value was entered for field: secret') 'An empty value was not refused.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'stdin.txt'))) 'An empty value reached the command.'

    $result = Invoke-Helper @{ Executable = 'no-such-command-for-secret-tests'; FieldValue = @{ secret = (New-Secure 'x') } }
    Assert-True ($null -ne $result.Error -and $result.Error -notmatch 'may have received') 'A missing command was reported as a possible send.'

    $batch = Join-Path $testRoot 'receiver.cmd'
    '@exit /b 0' | Set-Content -LiteralPath $batch -Encoding ascii
    $result = Invoke-Helper @{ Executable = $batch; ArgumentsJson = '[]'; FieldValue = @{ secret = (New-Secure 'x') } }
    Assert-True ($result.Error -match 'not a batch file') 'A batch receiver was accepted.'

    $result = Invoke-Helper @{ ConcealedField = 'a,b'; FieldValue = @{} }
    Assert-True ($result.Error -match 'exactly one field') 'Value format accepted several fields.'

    $result = Invoke-Helper @{ ArgumentsJson = '[1]'; FieldValue = @{} }
    Assert-True ($result.Error -match 'array of strings') 'Non-string arguments were accepted.'

    $result = Invoke-Helper @{ ConcealedField = 'Bad Name'; FieldValue = @{} }
    Assert-True ($result.Error -match 'Field names need') 'An invalid field name was accepted.'

    $result = Invoke-Helper @{ TextField = 'secret'; FieldValue = @{} }
    Assert-True ($result.Error -match 'unique') 'Duplicate field names were accepted.'
} finally {
    $env:FAKE_RECEIVER_ROOT = $oldRoot
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host "store-secret-from-dialog tests: $assertions assertions OK"
exit 0
