---
name: managed-jobs
description: Contain, run, verify readiness, inspect, recover, and stop long-running local Windows processes with explicit lifetimes, optional visible output, and durable logs. Use for dev servers, watchers, paid CLI agents, and lengthy builds or tests that may outlive a tool call. Do not use for ordinary short commands, non-Windows hosts, remote monitoring, or shared-terminal interaction.
---

# Managed Jobs

Resolve `$managedJobsSkillDirectory` to this file's directory, then use:

```powershell
$jobs = Join-Path $managedJobsSkillDirectory 'scripts\Invoke-ManagedJob.ps1'
$repo = git rev-parse --show-toplevel 2>$null
if ([string]::IsNullOrWhiteSpace($repo)) { $repo = (Get-Location).Path }
```

## Run and inspect

```powershell
$job = (& $jobs start -Name api -Executable dotnet -Arguments @('run') `
    -WorkingDirectory $repo | Out-String) | ConvertFrom-Json
& $jobs status -Id $job.id
& $jobs logs -Id $job.id -Tail 100
```

- Keep short commands attached to the active tool call.
- Default long work to hidden supervised execution. The installed startup hook
  reconciles global state asynchronously; do not run `reconcile` around starts.
- `Auto` uses the current agent turn when ownership is available. Use
  `-Lifetime Session` only across turns and `Persistent` only across sessions.
- Use the returned job instead of a global `list`; target `status` when needed.
- Treat arguments, environment values, records, and logs as non-secret.
- Add `-Visible` only when the user asks to watch output. `-KeepTerminalOpen`
  leaves a completed terminal for the user to close manually.
- Never replace this controller with a detached/background launch. Use
  `claude-runner` for Claude session, resume, and review behavior.

Stop completed or unneeded work:

```powershell
& $jobs stop -Id <job-id>
```

Hand off the id, status, lifetime, log path, working directory, and exact
status/logs/stop commands for any session or persistent job left running.

## HTTP readiness

When downstream work needs a local service immediately, add a credential-free
loopback HTTP(S) readiness gate to `start`:

```powershell
$job = (& $jobs start -Name api -Executable dotnet -Arguments @('run') `
    -WorkingDirectory $repo -ReadinessUri 'http://127.0.0.1:5000/health' `
    -ReadinessTimeoutSeconds 60 | Out-String) | ConvertFrom-Json
```

The gate returns after a 2xx/3xx response and stops only the newly created job
on timeout. Use `wait-ready -Id <job-id> -ReadinessUri <loopback-url>` to probe
an existing job without stopping it on failure.

## Advanced operations

The installed session hook owns global reconciliation. Run synchronous
`reconcile` only to retry a reported hook failure. Preview destructive cleanup
with `prune -OlderThanDays 14 -WhatIf`, obtain explicit authorization for the
reported scope, then run the same command without `-WhatIf`.

The HTTP readiness workflow adapts Open Mercato's
`om-prepare-test-env` under the MIT License; see
[open-mercato-license.md](references/open-mercato-license.md).
