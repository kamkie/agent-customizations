---
name: store-secret-from-dialog
description: Store a secret that only the user knows, such as a password, token or API key, without the value passing through chat, by opening a masked Windows input dialog that sends what the user types to a command's standard input, such as a secret store or CI CLI. Use when an authorized task needs a credential the user must type in, or when the user offers to paste a secret into chat. Do not use to read, reveal or rotate existing secrets, to inject credentials into commands that take them only as arguments, to type into a shared terminal, or on non-Windows hosts.
---

# Store a Secret from a Dialog

Never ask for a secret value in chat, in a captured terminal prompt, in a file or in command arguments. The bundled script opens a masked dialog on the user's desktop, writes the typed values to a receiving command's stdin, discards that command's output (it could echo the values), and prints only the exit code.

## Before running

- Sending the secret is a write to its destination. The user's request must cover the destination, the secret's name there and its purpose. Follow the active repository's credential rules for which store and command to use and how that command may be run.
- Pick a receiving command that reads the secret from stdin, for example `gh secret set <name>` or `docker login --password-stdin`. A command that takes a secret only as an argument does not qualify: arguments are visible to other processes. It must be a native executable; the script refuses `.cmd` and `.bat` wrappers, because `cmd.exe` can rewrite their arguments.
- Many receivers create or replace, as `gh secret set` does. Use such a receiver only when the user has authorized replacing a secret of that name. A check beforehand cannot prevent the replacement, because someone can add the name while the dialog is open. For a request to create only, use a receiver that refuses an existing name; if none exists, ask the user whether replacing is acceptable. Pass the same scope flags to every lookup and to the write, for example `--repo <owner>/<repo>` on both `gh secret list` and `gh secret set`.
- Fields are lowercase letters, digits, `_` or `-`, starting with a letter. Concealed fields are masked; text fields show what is typed. Pass several names as one comma-separated argument, such as `'-TextField', 'username'` with `'-ConcealedField', 'password,otp-seed'`.
- `-StdinFormat Value`, the default, sends one field's raw value with no trailing newline. `-StdinFormat Json` sends one object mapping each field name to its value.

## Run

The dialog waits for the user for as long as they need, so run it as a managed job. Resolve `$storeSecretSkillDirectory` to this file's directory; the `managed-jobs` skill sits beside it. The receiving command's arguments travel as one JSON array:

```powershell
$skillsRoot = Split-Path -Parent $storeSecretSkillDirectory
$jobs = Join-Path $skillsRoot 'managed-jobs/scripts/Invoke-ManagedJob.ps1'
$dialog = Join-Path $storeSecretSkillDirectory 'scripts/Send-SecretFromDialog.ps1'
$commandArguments = ConvertTo-Json -Compress -InputObject @('secret', 'set', '<secret-name>', '--repo', '<owner>/<repo>')
$job = (& $jobs start -Name secret-dialog -Executable pwsh -Arguments @(
        '-NoProfile', '-File', $dialog,
        '-Title', '<what the user is entering>',
        '-Executable', 'gh', '-ArgumentsJson', $commandArguments
    ) -WorkingDirectory (Get-Location).Path | Out-String) | ConvertFrom-Json
```

Tell the user that a dialog titled `<what the user is entering>` is opening. Ask them to select it (it has its own taskbar button) and click into each field before typing, since Windows may leave keyboard focus in the window they were using. Name the fields to fill. Then wait for it:

```powershell
$final = (& $jobs wait -Id $job.id -TimeoutSeconds 540 | Out-String) | ConvertFrom-Json
```

While `$final.timedOut` is `true`, the job is still running and the dialog may be open: run the same `wait` again. Do not stop the job unless the user abandons the entry.

## Result

Read the outcome from `$final.status`, `$final.exitCode` and `& $jobs logs -Id $job.id -Tail 40`. The log holds only the command name, exit codes and error messages, never values.

- **Exit code 0:** the log ends in JSON with `exitCode` 0. Report success, and confirm the result through the destination's metadata if the task needs proof. Never read the secret back.
- **Any other ending:** the script logs `Sending the secret to <command>.` immediately before the command receives the values. Search the full log for it with `Select-String -LiteralPath $final.logPath -Pattern '^Sending the secret to '`.
  - **Status `failed` with an exit code and no such line:** the script ended before sending anything. Report the logged reason, such as canceled input, an empty field or a command that was not found.
  - **Line present, or the job ended `stopped` or `orphaned` or without an exit code:** the command may have received the secret, because an interrupted job can lose the line. Check the destination by its metadata, without reading the value, and report what you find. If the result is unclear, report the outcome as unknown and ask the user before opening the dialog again.

`-FieldValue` takes a hashtable of `SecureString` values and skips the dialog. It exists for tests; never use it to pass a value the user gave you.
