---
name: managed-jobs
description: Run, inspect, recover, and stop long-running local processes on Windows with durable state and logs across agent restarts. Use for dev servers, watchers, paid CLI agents, and lengthy builds or tests that must outlive a turn. Do not use for ordinary short commands, non-Windows hosts, or work that should remain attached to the active tool call.
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
- Default long-lived work to hidden durable execution; record the returned id,
  current status, and log path.
- Reconcile after restarts and reuse an equivalent active job.
- Session start reconciles managed jobs silently. Inspect job state only when it
  is relevant to the current task; equivalent active launches are rejected.
- Treat arguments, environment entries, records, and logs as non-secret.
- Use visible Windows Terminal mode only when the user asks to watch the output.
- Never replace the controller with direct detached/background process commands.
- Use `claude-runner` for Claude session, resume, budget, and review behavior.
- Leave an active job running when it must outlive the turn. Hand off its id,
  status, log path, working directory, and the exact status/logs/stop commands.

Stop only after the work is complete or when the user explicitly asks:

```powershell
& $jobs stop -Id <job-id>
```

Read [operations.md](references/operations.md) for shared state roots, secret
handling, structured recovery, identity checks, visible options, and pruning.
