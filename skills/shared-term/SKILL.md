---
name: shared-term
description: Open and operate a visible collaborative Windows Terminal pane shared by the user and agent. Use when the user says `shared term`, asks for a shared terminal, or wants to watch and type in the same managed pane. Do not use for hidden background processes, ordinary visible output, or non-Windows hosts.
---

# Shared Terminal

Resolve `$sharedTermSkillDirectory` to this file's directory. The installed
`managed-jobs` controller is the process backend:

```powershell
$skillsRoot = Split-Path -Parent $sharedTermSkillDirectory
$controller = Join-Path $skillsRoot 'managed-jobs\scripts\Invoke-ManagedJob.ps1'
$repo = git rev-parse --show-toplevel 2>$null
if ([string]::IsNullOrWhiteSpace($repo)) { $repo = (Get-Location).Path }
$job = (& $controller start -Name console -Executable pwsh.exe `
    -Arguments @('-NoProfile') -WorkingDirectory $repo -Visible `
    -SharedTerminal -Lifetime Session | Out-String) | ConvertFrom-Json
[pscustomobject]@{ controller = $controller; job = $job } | ConvertTo-Json -Depth 12
```

Use the returned job directly. Do not run `reconcile` or `list` around the
launch. Add `-RequireBackgroundTab` only when focus must not change; it fails
instead of opening a foreground terminal window.

Operate only the registered pane:

```powershell
& $controller capture -Id $job.id -MaxLines 80
& $controller send-input -Id $job.id -InputText '<non-secret-text>'
& $controller send-key -Id $job.id -Key Enter
& $controller send-key -Id $job.id -Key 'Ctrl+C'
& $controller stop -Id $job.id
```

`send-input` is literal. Never send credentials; the user types them directly.
Do not capture while a secret prompt is waiting. Treat captured pane content as
sensitive and never copy it into logs, records, or other durable artifacts.

After a launch, report only the requested result and job id. Keep controller
commands internal; print them only when the user explicitly asks how to control
the pane. For later operations, answer only the current request.
