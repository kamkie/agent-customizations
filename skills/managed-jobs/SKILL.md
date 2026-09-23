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

Stop running work that is no longer needed; a terminal job needs no stop call:

```powershell
& $jobs stop -Id <job-id>
```

Hand off the id, status, lifetime, log path, working directory, and exact
status/logs/stop commands for any session or persistent job left running.

## Agent progress and completion

For a CLI agent or an agent-driven test, track three separate facts: the managed
process state, the native session's latest completed tool/output event, and the
required result artifacts. A live PID, startup log or heartbeat proves liveness,
not useful progress. Inspect the returned job and its native session/log paths;
use a filtered registry lookup only to recover a lost job ID, not as routine
polling. Preserve the PID/start identity when diagnosing a vanished supervisor.

A coordinator's final message does not establish that its child workers finished.
Keep the owner waiting through the runtime's supported completion mechanism;
check child terminal state and required artifacts before workspace teardown.
Inspect interruption timestamps and effective child settings before assigning
the failure to the model, wrapper or harness. Reuse a recoverable session rather
than launching a duplicate paid attempt without the applicable retry authority.

If a final usage/export record is absent, inspect native usage events before
calling it lost. For comparisons, report cost per completed attempt separately
from failures/retries, orchestration and grading. Missing cost stays unknown.
Retain failure evidence; cleanup may remove only this job's owned scratch paths,
not another task's logs or review inputs.

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

Set `MANAGED_JOBS_ROOT` before starting either agent when they must share a
non-default registry. One-off `-StateRoot` overrides are only for persistent
jobs; turn and session jobs must remain visible to their cleanup hooks.

The HTTP readiness workflow adapts Open Mercato's
`om-prepare-test-env` under the MIT License; see
[open-mercato-license.md](references/open-mercato-license.md).
