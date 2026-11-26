---
name: store-secret-from-dialog
description: Store a secret that only the user knows, such as a password, token or API key, as a new 1Password item without the value passing through chat, by opening a masked Windows input dialog that returns only the new item's op:// references. Use when an authorized task needs a credential the user must type in, or when the user offers to paste a secret into chat. Do not use to read, reveal, rotate or edit existing secrets, to inject credentials into commands, to type into a shared terminal, or on non-Windows hosts.
---

# Store a Secret from a Dialog

Never ask for a secret value in chat, in a captured terminal prompt, in a file or in command arguments. The bundled script opens a masked dialog on the user's desktop, streams the values to `op item create` on stdin, and prints only the new item's `op://` references.

## Before running

- Creating the item is a 1Password write. The user's request must cover the exact vault, item title and purpose. Follow the active repository's credential rules for which vault to use and how `op` may be run.
- Pick field names of lowercase letters, digits, `_` or `-`, starting with a letter. Text fields show what is typed; concealed fields are masked. Separate several names with commas. The defaults are `username` (text) and `password` (concealed).
- When the user has more than one 1Password account, add `'-Account', '<account>'` to the arguments below. The script binds the vault to its ID before the dialog opens, so a later change of op's default account fails the write instead of redirecting it.
- The script refuses a title that already exists in the vault, checking before the dialog and again just before the write, and never edits an item. 1Password allows duplicate titles, so a writer elsewhere can still add the same title in the moment between that check and the write.

## Run

The dialog waits for the user for as long as they need, so run it as a managed job. Resolve `$storeSecretSkillDirectory` to this file's directory; the `managed-jobs` skill sits beside it:

```powershell
$skillsRoot = Split-Path -Parent $storeSecretSkillDirectory
$jobs = Join-Path $skillsRoot 'managed-jobs/scripts/Invoke-ManagedJob.ps1'
$dialog = Join-Path $storeSecretSkillDirectory 'scripts/New-1PasswordItemFromDialog.ps1'
$job = (& $jobs start -Name secret-dialog -Executable pwsh -Arguments @(
        '-NoProfile', '-File', $dialog,
        '-Vault', '<vault>', '-Title', '<item-title>',
        '-TextField', 'username', '-ConcealedField', 'password'
    ) -WorkingDirectory (Get-Location).Path | Out-String) | ConvertFrom-Json
```

Tell the user that the dialog is open (it may first show a 1Password sign-in approval) and which fields to fill. Then wait for it:

```powershell
$final = (& $jobs wait -Id $job.id -TimeoutSeconds 540 | Out-String) | ConvertFrom-Json
```

While `$final.timedOut` is `true`, the dialog is still open: run the same `wait` again. Do not stop the job unless the user abandons the entry.

## Result

Read the outcome with `& $jobs logs -Id $job.id -Tail 40`. The log holds only references and error messages, never values.

- **Exit code 0:** the log ends in JSON with `vaultId`, `itemId` and one `op://<vault-id>/<item-id>/<field>` reference per field. Report the references and record them where the active repository keeps credential locators. Do not read the item back to check it.
- **Any other exit:** nothing was stored. Report the logged reason: the user canceled, left a field empty, sign-in failed, or the title already exists. For an existing title, ask for a new title; editing the existing item is outside this skill.

`-FieldValue` takes a hashtable of `SecureString` values and skips the dialog. It exists for tests; never use it to pass a value the user gave you.
