[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helper = Join-Path $PSScriptRoot '..\scripts\New-1PasswordItemFromDialog.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('store-secret-from-dialog-tests-' + [guid]::NewGuid().ToString('N'))
# A .cmd wrapper makes the fake a native process, so its stdin and stderr behave like op's.
$fakeOp = Join-Path $testRoot 'op.cmd'
$fakeImplementation = Join-Path $testRoot 'op-impl.ps1'
$oldRoot = $env:FAKE_OP_ROOT
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

function Reset-FakeOp([string[]]$ExistingTitles = @(), [string]$CreateMode = 'ok') {
    Get-ChildItem -LiteralPath $testRoot -Filter '*.txt' | Remove-Item
    $items = @($ExistingTitles | ForEach-Object { @{ id = 'old'; title = $_ } })
    ConvertTo-Json -InputObject $items | Set-Content -LiteralPath (Join-Path $testRoot 'existing.json')
    Set-Content -LiteralPath (Join-Path $testRoot 'create-mode.cfg') -Value $CreateMode
}

function Invoke-Dialog([hashtable]$Parameters) {
    $arguments = @{ Vault = 'test-vault'; OpExecutable = $fakeOp }
    foreach ($key in $Parameters.Keys) { $arguments[$key] = $Parameters[$key] }
    try {
        $output = & $helper @arguments 6>$null | Out-String
        [pscustomobject]@{ Output = $output; Error = $null }
    } catch {
        [pscustomobject]@{ Output = ''; Error = $_.Exception.Message }
    }
}

# Runs the helper as its own process and returns both streams together, as a managed-job log holds them.
function Invoke-DialogProcess([string]$Title, [string]$Password) {
    $command = "& '$helper' -Vault 'test-vault' -Title '$Title' -OpExecutable '$fakeOp' " +
        "-FieldValue @{ username = (ConvertTo-SecureString 'svc-user' -AsPlainText -Force); " +
        "password = (ConvertTo-SecureString '$Password' -AsPlainText -Force) }"
    $output = & pwsh -NoProfile -Command $command 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Log = $output }
}

$null = New-Item -ItemType Directory -Path $testRoot
"@pwsh -NoProfile -File `"%~dp0op-impl.ps1`" %*`r`n@exit /b %ERRORLEVEL%" | Set-Content -LiteralPath $fakeOp -Encoding ascii
@'
$root = $env:FAKE_OP_ROOT
Add-Content -LiteralPath (Join-Path $root 'argv.txt') -Value ($args -join ' ')
switch ($args[0]) {
    'signin' { exit 0 }
    'vault' { if ($args[2] -eq 'test-vault') { '{"id":"vault-1","name":"test-vault"}'; exit 0 }; exit 1 }
    'item' {
        if ($args[1] -eq 'list') {
            # A later-listed title simulates someone adding it while the dialog is open.
            $countFile = Join-Path $root 'list-count.txt'
            $count = 1 + [int](Get-Content -LiteralPath $countFile -ErrorAction SilentlyContinue)
            Set-Content -LiteralPath $countFile -Value $count
            $late = Join-Path $root 'existing-late.json'
            if ($count -gt 1 -and (Test-Path -LiteralPath $late)) { Get-Content -LiteralPath $late -Raw; exit 0 }
            Get-Content -LiteralPath (Join-Path $root 'existing.json') -Raw; exit 0
        }
        if ($args[1] -eq 'create') {
            $stdin = [Console]::In.ReadToEnd()
            Set-Content -LiteralPath (Join-Path $root 'stdin.txt') -Value $stdin
            switch ((Get-Content -LiteralPath (Join-Path $root 'create-mode.cfg') -Raw).Trim()) {
                'fail-echo' { [Console]::Error.WriteLine("invalid template: $stdin"); exit 1 }
                'garbage' { "unreadable $stdin"; [Console]::Error.WriteLine("warning: $stdin"); exit 0 }
                'no-vault-id' { '{"id":"item-1"}'; exit 0 }
                default { '{"id":"item-1","vault":{"id":"vault-1"},"fields":[{"value":"leaked-if-printed"}]}'; exit 0 }
            }
        }
    }
}
exit 9
'@ | Set-Content -LiteralPath $fakeImplementation

try {
    $env:FAKE_OP_ROOT = $testRoot

    Reset-FakeOp
    $result = Invoke-Dialog @{
        Title = 'Service login'
        FieldValue = @{ username = (New-Secure 'svc-user'); password = (New-Secure 'S3cret-value') }
    }
    Assert-True ($null -eq $result.Error) "Successful creation failed: $($result.Error)"
    $parsed = $result.Output | ConvertFrom-Json
    Assert-True ($parsed.references.username -eq 'op://vault-1/item-1/username') 'Username reference is wrong.'
    Assert-True ($parsed.references.password -eq 'op://vault-1/item-1/password') 'Password reference is wrong.'
    Assert-True ($result.Output -notmatch 'S3cret-value|svc-user|leaked-if-printed') 'Output contains a field value.'
    $argv = Get-Content -LiteralPath (Join-Path $testRoot 'argv.txt') -Raw
    Assert-True ($argv -notmatch 'S3cret-value|svc-user') 'A value reached op through its arguments.'
    Assert-True ($argv -match '(?m)^item list --vault vault-1 ' -and $argv -match '(?m)^item create --vault vault-1 ') 'List and create did not use the bound vault ID.'
    $template = Get-Content -LiteralPath (Join-Path $testRoot 'stdin.txt') -Raw | ConvertFrom-Json
    $password = $template.fields | Where-Object id -eq 'password'
    $username = $template.fields | Where-Object id -eq 'username'
    Assert-True ($template.title -ceq 'Service login' -and $template.category -eq 'LOGIN') 'Template header is wrong.'
    Assert-True ($password.value -ceq 'S3cret-value' -and $password.type -eq 'CONCEALED' -and $password.purpose -eq 'PASSWORD') 'Password field is wrong.'
    Assert-True ($username.value -ceq 'svc-user' -and $username.type -eq 'STRING' -and $username.purpose -eq 'USERNAME') 'Username field is wrong.'

    Reset-FakeOp
    $result = Invoke-Dialog @{ Title = 'Bound'; Account = 'team.example.com'; FieldValue = @{ username = (New-Secure 'u'); password = (New-Secure 'p') } }
    Assert-True ($null -eq $result.Error) "Account-bound creation failed: $($result.Error)"
    $argvLines = @(Get-Content -LiteralPath (Join-Path $testRoot 'argv.txt'))
    Assert-True ($argvLines.Count -ge 4 -and @($argvLines | Where-Object { $_ -notmatch '--account team\.example\.com' }).Count -eq 0) 'An op call did not carry the bound account.'

    Reset-FakeOp
    $result = Invoke-Dialog @{ Title = 'Nowhere'; Vault = 'missing-vault'; FieldValue = @{ username = (New-Secure 'u'); password = (New-Secure 'p') } }
    Assert-True ($result.Error -match 'Could not find the 1Password vault') 'A missing vault was not refused.'

    Reset-FakeOp -CreateMode 'fail-echo'
    $run = Invoke-DialogProcess -Title 'Echoed failure' -Password 'Synthetic-Echo-1'
    Assert-True ($run.ExitCode -ne 0) 'A failed create did not fail the helper.'
    Assert-True ($run.Log -match 'The item may exist: op exit code 1 .*Check vault ID vault-1') "A failed create was not reported as an unknown outcome in the bound vault: $($run.Log)"
    Assert-True ($run.Log -match '(?m)^Sending the item to op in vault ID vault-1\.') 'The log does not record the bound vault ID before the write.'
    Assert-True ($run.Log -notmatch 'Synthetic-Echo-1|svc-user') 'op diagnostics leaked a value into the helper streams.'

    Reset-FakeOp -CreateMode 'garbage'
    $run = Invoke-DialogProcess -Title 'Unreadable reply' -Password 'Synthetic-Echo-2'
    Assert-True ($run.ExitCode -ne 0) 'An unreadable create response did not fail the helper.'
    Assert-True ($run.Log -match 'The item may exist: op exit code 0 .*Check vault ID vault-1') "An unreadable create response was not reported as an unknown outcome: $($run.Log)"
    Assert-True ($run.Log -notmatch 'Synthetic-Echo-2|svc-user') 'An unreadable create response leaked a value into the helper streams.'

    # A PowerShell wrapper around op can complete the write and then throw.
    Reset-FakeOp
    $throwingOp = Join-Path $testRoot 'op-throws.ps1'
    @'
if ($args[0] -eq 'item' -and $args[1] -eq 'create') { throw "wrapper failed after write: $(@($input) -join '')" }
& (Join-Path $env:FAKE_OP_ROOT 'op.cmd') @args
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $throwingOp
    $result = Invoke-Dialog @{ Title = 'Thrown create'; OpExecutable = $throwingOp; FieldValue = @{ username = (New-Secure 'u'); password = (New-Secure 'Synthetic-Throw-4') } }
    Assert-True ($result.Error -match 'The item may exist: op exit code unknown .*Check vault ID vault-1') "A thrown create was not reported as an unknown outcome: $($result.Error)"
    Assert-True ($result.Error -notmatch 'Synthetic-Throw-4') 'A thrown create leaked a value into the error.'

    Reset-FakeOp -CreateMode 'no-vault-id'
    $run = Invoke-DialogProcess -Title 'Partial receipt' -Password 'Synthetic-Echo-3'
    Assert-True ($run.ExitCode -ne 0) 'A receipt without a vault ID did not fail the helper.'
    Assert-True ($run.Log -match 'The item may exist: op exit code 0 .*Check vault ID vault-1') "A receipt without a vault ID was not reported as an unknown outcome: $($run.Log)"
    Assert-True ($run.Log -notmatch 'Synthetic-Echo-3|svc-user') 'A receipt without a vault ID leaked a value into the helper streams.'

    Reset-FakeOp
    $result = Invoke-Dialog @{
        Title = 'Api key'
        TextField = 'account,region'
        ConcealedField = 'api-key'
        FieldValue = @{ account = (New-Secure 'a'); region = (New-Secure 'r'); 'api-key' = (New-Secure 'k') }
    }
    Assert-True ($null -eq $result.Error) "Comma-separated fields failed: $($result.Error)"
    $names = @((Get-Content -LiteralPath (Join-Path $testRoot 'stdin.txt') -Raw | ConvertFrom-Json).fields.id) -join ','
    Assert-True ($names -eq 'account,region,api-key') "Comma-separated fields were not split: $names"

    Reset-FakeOp -ExistingTitles 'Before write'
    $run = Invoke-DialogProcess -Title 'Before write' -Password 'p'
    Assert-True ($run.ExitCode -ne 0 -and $run.Log -notmatch 'Sending the item to op') 'A failure before the write logged the write marker.'

    Reset-FakeOp -ExistingTitles 'Service login'
    $result = Invoke-Dialog @{ Title = 'Service login'; FieldValue = @{ username = (New-Secure 'u'); password = (New-Secure 'p') } }
    Assert-True ($result.Error -match 'already exists') 'An existing title was not refused.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'stdin.txt'))) 'An item was created over an existing title.'

    Reset-FakeOp
    '[{"id":"new","title":"Raced login"}]' | Set-Content -LiteralPath (Join-Path $testRoot 'existing-late.json')
    $result = Invoke-Dialog @{ Title = 'Raced login'; FieldValue = @{ username = (New-Secure 'u'); password = (New-Secure 'p') } }
    Remove-Item -LiteralPath (Join-Path $testRoot 'existing-late.json')
    Assert-True ($result.Error -match 'already exists') 'A title added while the dialog was open was not refused.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'stdin.txt'))) 'An item was created over a title added while the dialog was open.'

    Reset-FakeOp
    $result = Invoke-Dialog @{ Title = 'Empty'; FieldValue = @{ username = (New-Secure 'u'); password = [Security.SecureString]::new() } }
    Assert-True ($result.Error -match 'No value was entered for field: password') 'An empty value was not refused.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'stdin.txt'))) 'An item was created with an empty value.'

    Reset-FakeOp
    $result = Invoke-Dialog @{ Title = 'Dup'; TextField = 'password'; FieldValue = @{} }
    Assert-True ($result.Error -match 'unique') 'Duplicate field names were not refused.'

    $result = Invoke-Dialog @{ Title = 'Bad'; TextField = 'User Name'; FieldValue = @{} }
    Assert-True ($result.Error -match 'Field names need') 'An invalid field name was not refused.'
} finally {
    $env:FAKE_OP_ROOT = $oldRoot
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host "store-secret-from-dialog tests: $assertions assertions OK"
exit 0
