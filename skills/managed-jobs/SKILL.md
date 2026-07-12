---
name: managed-jobs
description: Run, inspect, recover, and stop long-running local processes with durable state and logs across agent restarts; visible Windows Terminal output is opt-in.
---

# Managed Jobs

Use the self-contained controller from this installed skill directory:

```powershell
$jobs = Join-Path $managedJobsSkillDirectory 'scripts\Invoke-ManagedJob.ps1'
```

Resolve `$managedJobsSkillDirectory` to the directory containing this file.
Read [operations.md](references/operations.md) before using the controller.

- Keep short commands attached to the active agent tool call.
- Default long-lived work to hidden durable execution and reuse equivalent jobs.
- Reconcile after restarts before starting or stopping work.
- Use visible Windows Terminal mode only when the user asks to watch the output.
- Never replace the controller with direct detached/background process commands.
- Use `claude-runner` for Claude session, resume, budget, and review behavior.
