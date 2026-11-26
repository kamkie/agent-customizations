#!/usr/bin/env pwsh
# Collects secret field values in a masked Windows dialog, streams them to
# `op item create` on stdin, and prints only the new item's op:// references.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Vault,

    [Parameter(Mandatory)]
    [string]$Title,

    # Field names; a comma-separated string also works, so `pwsh -File` can pass several.
    [string[]]$TextField = @('username'),

    [string[]]$ConcealedField = @('password'),

    # Field name -> SecureString. Skips the dialog; for tests only.
    [hashtable]$FieldValue,

    [string]$OpExecutable = 'op'
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Read-SecretDialog {
    param([string]$Title, [string[]]$TextField, [string[]]$ConcealedField)

    if (-not $IsWindows) { throw 'The secret input dialog requires Windows.' }
    Add-Type -AssemblyName System.Windows.Forms
    if (-not ('SecretFromDialog.Native' -as [type])) {
        Add-Type -Namespace SecretFromDialog -Name Native -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
public static extern void SetCurrentProcessExplicitAppUserModelID(string appId);
'@
    }
    # Agents usually run this in a hidden PowerShell host. An app ID of its own
    # gives the dialog a separate taskbar button instead of hiding it in the
    # PowerShell group.
    [SecretFromDialog.Native]::SetCurrentProcessExplicitAppUserModelID('AgentCustomizations.SecretDialog')

    $form = [Windows.Forms.Form]::new()
    $form.Text = "New 1Password item: $Title"
    $form.Icon = [Drawing.SystemIcons]::Shield
    $form.ShowInTaskbar = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.StartPosition = 'CenterScreen'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.Add_Shown({ $this.Activate() })

    $boxes = [ordered]@{}
    $top = 16
    foreach ($name in @($TextField) + @($ConcealedField)) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = $name
        $label.SetBounds(16, $top + 3, 120, 20)
        $box = [Windows.Forms.TextBox]::new()
        $box.SetBounds(140, $top, 284, 23)
        $box.UseSystemPasswordChar = $name -in $ConcealedField
        $form.Controls.AddRange(@($label, $box))
        $boxes[$name] = $box
        $top += 34
    }

    $ok = [Windows.Forms.Button]::new()
    $ok.Text = 'Store'
    $ok.DialogResult = 'OK'
    $ok.SetBounds(254, $top + 4, 80, 28)
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = 'Cancel'
    $cancel.DialogResult = 'Cancel'
    $cancel.SetBounds(344, $top + 4, 80, 28)
    $form.Controls.AddRange(@($ok, $cancel))
    $form.AcceptButton = $ok
    $form.CancelButton = $cancel
    $form.ClientSize = [Drawing.Size]::new(440, $top + 48)

    try {
        if ($form.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
            throw 'Secret input was canceled; nothing was stored.'
        }
        $values = [ordered]@{}
        foreach ($name in $boxes.Keys) { $values[$name] = $boxes[$name].Text }
        return $values
    } finally {
        foreach ($box in $boxes.Values) { $box.Clear() }
        $form.Dispose()
    }
}

$TextField = @($TextField -split ',' | ForEach-Object Trim | Where-Object { $_ })
$ConcealedField = @($ConcealedField -split ',' | ForEach-Object Trim | Where-Object { $_ })
$fieldNames = @($TextField) + @($ConcealedField)
if ($fieldNames.Count -eq 0) { throw 'At least one field is required.' }
foreach ($name in $fieldNames) {
    if ($name -cnotmatch '^[a-z][a-z0-9_-]{0,62}$') {
        throw "Field names need lowercase letters, digits, '_' or '-', starting with a letter: $name"
    }
}
if (@($fieldNames | Sort-Object -Unique).Count -ne $fieldNames.Count) {
    throw 'Field names must be unique.'
}

$op = (Get-Command $OpExecutable -CommandType Application, ExternalScript -ErrorAction Stop).Source
& $op signin | Out-Null
if ($LASTEXITCODE -ne 0) { throw '1Password sign-in failed.' }

# `item list` carries no field values, unlike `item get`.
$existingJson = & $op item list --vault $Vault --format json | Out-String
if ($LASTEXITCODE -ne 0) { throw "Could not list items in the 1Password vault: $Vault" }
if (@($existingJson | ConvertFrom-Json | Where-Object { $_.title -ceq $Title }).Count -gt 0) {
    throw "A 1Password item with this title already exists in the vault: $Title"
}

if ($FieldValue) {
    $values = [ordered]@{}
    foreach ($name in $fieldNames) {
        if ($FieldValue[$name] -isnot [Security.SecureString]) {
            throw "FieldValue needs a SecureString for field: $name"
        }
        $values[$name] = [Net.NetworkCredential]::new('', $FieldValue[$name]).Password
    }
} else {
    $values = Read-SecretDialog -Title $Title -TextField $TextField -ConcealedField $ConcealedField
}

try {
    $fields = foreach ($name in $fieldNames) {
        if ([string]::IsNullOrEmpty($values[$name])) { throw "No value was entered for field: $name" }
        $field = [ordered]@{
            id = $name
            type = if ($name -in $ConcealedField) { 'CONCEALED' } else { 'STRING' }
            label = $name
            value = $values[$name]
        }
        if ($name -ceq 'username') { $field.purpose = 'USERNAME' }
        if ($name -ceq 'password') { $field.purpose = 'PASSWORD' }
        $field
    }
    $template = [ordered]@{ title = $Title; category = 'LOGIN'; fields = @($fields) } |
        ConvertTo-Json -Depth 5

    # The template reaches op on stdin only; the captured result is parsed and never printed.
    $created = $template | & $op item create --vault $Vault --format json - | Out-String
    if ($LASTEXITCODE -ne 0) { throw '1Password item creation failed.' }
    $item = $created | ConvertFrom-Json
    $references = [ordered]@{}
    foreach ($name in $fieldNames) {
        $references[$name] = "op://$($item.vault.id)/$($item.id)/$name"
    }
    [pscustomobject]@{
        title = $Title
        vaultId = [string]$item.vault.id
        itemId = [string]$item.id
        references = $references
    } | ConvertTo-Json
} finally {
    $values = $null
    $fields = $null
    $template = $null
    $created = $null
    $item = $null
}
