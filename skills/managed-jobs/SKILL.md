---
name: managed-jobs
description: Contain, run, inspect, recover, and stop long-running local processes on Windows with explicit lifetimes, durable state, and logs. Use for dev servers, watchers, paid CLI agents, and lengthy builds or tests that may outlive a tool call. Do not use for ordinary short commands, non-Windows hosts, or work that should remain attached to the active tool call.
---

# Managed Jobs

Resolve `$managedJobsSkillDirectory` to this file's directory, then use:

```powershell
$jobs = Join-Path $managedJobsSkillDirectory 'scripts\Invoke-ManagedJob.ps1'
$repo = git rev-parse --show-toplevel 2>$null
if ([string]::IsNullOrWhiteSpace($repo)) { $repo = (Get-Location).Path }
```

## Happy path

```powershell
& $jobs reconcile
& $jobs start -Name api -Executable dotnet -Arguments @('run') -WorkingDirectory $repo
& $jobs list -Status running,starting -Json
& $jobs status -Id <job-id>
& $jobs logs -Id <job-id> -Tail 100
```

- Keep short commands attached to the active agent tool call.
- Default long-lived work to hidden supervised execution; record the returned id,
  current status, and log path.
- On Codex, the default lifetime is the current turn. Use `-Lifetime Session`
  only when the process must remain available across turns, and use
  `-Lifetime Persistent` only when it must intentionally survive the session.
- Reconcile after restarts and reuse an equivalent active job.
- Treat arguments, environment entries, records, and logs as non-secret.
- Use visible Windows Terminal mode only when the user asks to watch the output.
- Never replace the controller with direct detached/background process commands.
- Use `claude-runner` for Claude session, resume, budget, and review behavior.
- Before ending a turn, stop work that is no longer needed. Hand off the id,
  status, lifetime, log path, working directory, and exact status/logs/stop
  commands for any session or persistent job intentionally left running.

Stop only after the work is complete or when the user explicitly asks:

```powershell
& $jobs stop -Id <job-id>
```

Read [operations.md](references/operations.md) for shared state roots, secret
handling, structured recovery, identity checks, visible options, and pruning.
