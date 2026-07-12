---
name: managed-jobs
description: Run, inspect, recover, and stop long-running local processes with durable state and logs across agent restarts; visible Windows Terminal output is opt-in.
---

# Managed Jobs

Resolve `$managedJobsSkillDirectory` to this file's directory, then use:

```powershell
$jobs = Join-Path $managedJobsSkillDirectory 'scripts\Invoke-ManagedJob.ps1'
```

## Happy path

```powershell
& $jobs reconcile
& $jobs start -Name api -Executable dotnet -Arguments @('run') -WorkingDirectory $repo
& $jobs list -Status running,starting -Json
& $jobs status -Id <job-id>
& $jobs logs -Id <job-id> -Tail 100
& $jobs stop -Id <job-id>
```

- Keep short commands attached to the active agent tool call.
- Default long-lived work to hidden durable execution; record the returned id.
- Reconcile after restarts and reuse an equivalent active job.
- Treat arguments, environment entries, records, and logs as non-secret.
- Use visible Windows Terminal mode only when the user asks to watch the output.
- Never replace the controller with direct detached/background process commands.
- Use `claude-runner` for Claude session, resume, budget, and review behavior.

Read [operations.md](references/operations.md) for shared state roots, secret
handling, structured recovery, identity checks, visible options, and pruning.
