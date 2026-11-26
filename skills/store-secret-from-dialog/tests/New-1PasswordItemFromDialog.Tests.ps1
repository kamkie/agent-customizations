[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helper = Join-Path $PSScriptRoot '..\scripts\New-1PasswordItemFromDialog.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('store-secret-from-dialog-tests-' + [guid]::NewGuid().ToString('N'))
$fakeOp = Join-Path $testRoot 'op.ps1'
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

function Reset-FakeOp([string[]]$ExistingTitles = @()) {
    Get-ChildItem -LiteralPath $testRoot -Filter '*.txt' | Remove-Item
    $items = @($ExistingTitles | ForEach-Object { @{ id = 'old'; title = $_ } })
    ConvertTo-Json -InputObject $items | Set-Content -LiteralPath (Join-Path $testRoot 'existing.json')
}

function Invoke-Dialog([hashtable]$Parameters) {
    try {
        $output = & $helper -Vault 'test-vault' -OpExecutable $fakeOp @Parameters 6>&1 | Out-String
        [pscustomobject]@{ Output = $output; Error = $null }
    } catch {
        [pscustomobject]@{ Output = ''; Error = $_.Exception.Message }
    }
}

$null = New-Item -ItemType Directory -Path $testRoot
@'
$root = $env:FAKE_OP_ROOT
Add-Content -LiteralPath (Join-Path $root 'argv.txt') -Value ($args -join ' ')
switch ($args[0]) {
    'signin' { exit 0 }
    'item' {
        if ($args[1] -eq 'list') { Get-Content -LiteralPath (Join-Path $root 'existing.json') -Raw; exit 0 }
        if ($args[1] -eq 'create') {
            ($input | Out-String) | Set-Content -LiteralPath (Join-Path $root 'stdin.txt')
            '{"id":"item-1","vault":{"id":"vault-1"},"fields":[{"value":"leaked-if-printed"}]}'
            exit 0
        }
    }
}
exit 9
'@ | Set-Content -LiteralPath $fakeOp

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
    $template = Get-Content -LiteralPath (Join-Path $testRoot 'stdin.txt') -Raw | ConvertFrom-Json
    $password = $template.fields | Where-Object id -eq 'password'
    $username = $template.fields | Where-Object id -eq 'username'
    Assert-True ($template.title -ceq 'Service login' -and $template.category -eq 'LOGIN') 'Template header is wrong.'
    Assert-True ($password.value -ceq 'S3cret-value' -and $password.type -eq 'CONCEALED' -and $password.purpose -eq 'PASSWORD') 'Password field is wrong.'
    Assert-True ($username.value -ceq 'svc-user' -and $username.type -eq 'STRING' -and $username.purpose -eq 'USERNAME') 'Username field is wrong.'

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

    Reset-FakeOp -ExistingTitles 'Service login'
    $result = Invoke-Dialog @{ Title = 'Service login'; FieldValue = @{ username = (New-Secure 'u'); password = (New-Secure 'p') } }
    Assert-True ($result.Error -match 'already exists') 'An existing title was not refused.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'stdin.txt'))) 'An item was created over an existing title.'

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
