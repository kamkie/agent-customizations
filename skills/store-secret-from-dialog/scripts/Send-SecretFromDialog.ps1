#!/usr/bin/env pwsh
# Collects secret field values in a masked Windows dialog and writes them to a
# command's standard input. The command's output never leaves this script; it
# prints only the command's exit code.
[CmdletBinding()]
param(
    # Shown in the dialog's title bar, so the user can tell what they are entering.
    [Parameter(Mandatory)]
    [string]$Title,

    # The command that receives the values on stdin, such as a secret store CLI.
    [Parameter(Mandatory)]
    [string]$Executable,

    # The command's arguments as one JSON array of strings, so `pwsh -File` can pass them.
    [string]$ArgumentsJson = '[]',

    # Masked fields; a comma-separated string also works.
    [string[]]$ConcealedField = @('secret'),

    # Visible fields, such as a user name; a comma-separated string also works.
    [string[]]$TextField = @(),

    # Value: the single field's raw value, with no trailing newline.
    # Json: one object mapping each field name to its value.
    [ValidateSet('Value', 'Json')]
    [string]$StdinFormat = 'Value',

    # Field name -> SecureString. Skips the dialog; for tests only.
    [hashtable]$FieldValue
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

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
    $form.Text = $Title
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
    $ok.Text = 'Send'
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
            throw 'Secret input was canceled; nothing was sent.'
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
if (@($fieldNames | Sort-Object -Unique).Count -ne $fieldNames.Count) { throw 'Field names must be unique.' }
if ($StdinFormat -eq 'Value' -and $fieldNames.Count -ne 1) { throw 'StdinFormat Value needs exactly one field; use Json for several.' }

$arguments = @($ArgumentsJson | ConvertFrom-Json)
if (@($arguments | Where-Object { $_ -isnot [string] }).Count -gt 0) { throw 'ArgumentsJson must be a JSON array of strings.' }
$command = (Get-Command $Executable -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
# Windows runs batch files through cmd.exe, whose parsing can rewrite the
# arguments that name the destination.
if ([IO.Path]::GetExtension($command) -in @('.cmd', '.bat')) {
    throw "The receiving command must be a native executable, not a batch file: $command"
}

if ($FieldValue) {
    $values = [ordered]@{}
    foreach ($name in $fieldNames) {
        if ($FieldValue[$name] -isnot [Security.SecureString]) { throw "FieldValue needs a SecureString for field: $name" }
        $values[$name] = [Net.NetworkCredential]::new('', $FieldValue[$name]).Password
    }
} else {
    $values = Read-SecretDialog -Title $Title -TextField $TextField -ConcealedField $ConcealedField
}

try {
    foreach ($name in $fieldNames) {
        if ([string]::IsNullOrEmpty($values[$name])) { throw "No value was entered for field: $name; nothing was sent." }
    }
    $payload = if ($StdinFormat -eq 'Value') { $values[$fieldNames[0]] } else { $values | ConvertTo-Json -Compress }

    $startInfo = [Diagnostics.ProcessStartInfo]::new($command)
    foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    # Recovery keys on this line: without it, the command never received the values.
    Write-Host "Sending the secret to $([IO.Path]::GetFileName($command))."
    $exitCode = 'unknown'
    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        # The command's output can echo the values, so it is read and discarded.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($payload)
        $process.StandardInput.Close()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        # A descendant of the receiver can keep its output pipes open after it
        # exits, so the drain gets a few seconds rather than waiting on them.
        try { $null = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 5000) } catch { }
    } catch {
        # Its message could carry the values.
        $exitCode = 'unknown'
    }
    if ($exitCode -ne 0) {
        throw "The command may have received the secret but did not report success (exit code $exitCode). Check its destination before retrying."
    }
    [pscustomobject]@{ title = $Title; command = [IO.Path]::GetFileName($command); exitCode = 0 } | ConvertTo-Json -Compress
} finally {
    $values = $null
    $payload = $null
    $stdout = $null
    $stderr = $null
}
