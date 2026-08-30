---
name: managed-jobs
description: Contain, run, verify readiness, inspect, interact with opt-in visible shared terminals, recover, and stop long-running local processes on Windows with explicit lifetimes, durable state, and logs. Use for dev servers, watchers, paid CLI agents, and lengthy builds or tests that may outlive a tool call. Do not use for ordinary short commands, non-Windows hosts, remote-service health monitoring, or work that should remain attached to the active tool call.
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
- In a Codex or Claude Code installation, the default lifetime is the current
  turn. Use `-Lifetime Session` only when the process must remain available
  across turns, and use `-Lifetime Persistent` only when it must intentionally
  survive the session.
- Reconcile after restarts and reuse an equivalent active job.
- For a local HTTP service, use the readiness gate before handing its URL to
  downstream work. The probe URL must use HTTP(S), target loopback, and contain
  no credentials, query, or fragment.
- Treat arguments, environment entries, records, and logs as non-secret.
- Use visible Windows Terminal mode only when the user asks to watch the output.
- Use shared-terminal mode only when the user needs bidirectional collaboration
  in that visible managed pane.
- Never replace the controller with direct detached/background process commands.
- When a hook denies a background or detached launch, start a managed job; a
  foreground retry bounded by a tool-call timeout is not an acceptable
  substitute for long-running work.
- Use `claude-runner` for Claude session, resume, and review behavior.
- Before ending a turn, stop work that is no longer needed. Hand off the id,
  status, lifetime, log path, working directory, and exact status/logs/stop
  commands for any session or persistent job intentionally left running.

Stop only after the work is complete or when the user explicitly asks:

```powershell
& $jobs stop -Id <job-id>
```

## Shared terminal

Shared-terminal mode is an explicit visible-only option. It uses the installed
Microsoft Intelligent Terminal package and keeps every controller action scoped
to the pane registered by that managed job. When Intelligent Terminal is
already running, the controller creates the managed pane as a background tab
without changing the user's foreground window or active pane. Otherwise it
shell-activates a new terminal window (foreground), waits for its protocol
registration, and creates the managed tab through the same protocol path:

```powershell
$job = (& $jobs start -Name console -Executable pwsh.exe `
    -Arguments @('-NoProfile') -WorkingDirectory $repo `
    -Visible -SharedTerminal | Out-String) | ConvertFrom-Json
& $jobs capture -Id $job.id -MaxLines 80
& $jobs send-input -Id $job.id -InputText 'Get-Location'
& $jobs send-key -Id $job.id -Key Enter
& $jobs send-key -Id $job.id -Key 'Ctrl+C'
```

Add `-RequireBackgroundTab` when focus must not change. It fails instead of
performing the foreground bootstrap when no protocol-registered Intelligent
Terminal window exists. The controller never stops an existing terminal
process; if activation cannot produce a registered window before the bootstrap
deadline, the launch fails with the leftover PID so the user can close it.

`send-input` is literal and is only for known non-secret text. Never send an
authentication secret through the controller; the user must type it directly
in the visible terminal. Do not automatically capture while a secret prompt is
waiting for user input. Treat all captured pane output as sensitive: return it
only to the active task and never copy it into a job record, ordinary managed
log, or other durable artifact.

Shared-terminal children inherit the pane streams directly so interactive
prompts remain intact. Their ordinary managed log contains lifecycle events,
not child output; capture any needed pane evidence while the job is running.
After exit, only the managed status, exit code, and lifecycle log remain.

Read [operations.md](references/operations.md) for shared state roots, secret
handling, structured recovery, identity checks, visible and shared-terminal
options, and pruning.

## HTTP readiness

When downstream work needs a local HTTP service immediately, replace the plain
`start` call above with a readiness-gated start:

```powershell
# Replace this example with the service's loopback health URL.
$readinessUri = [uri]'http://127.0.0.1:5000/health'
$job = (& $jobs start -Name api -Executable dotnet -Arguments @('run') `
    -WorkingDirectory $repo -ReadinessUri $readinessUri `
    -ReadinessTimeoutSeconds 60 | Out-String) | ConvertFrom-Json
```

The command returns only after a 2xx or 3xx response and includes structured
`readiness` evidence. If the deadline expires, it stops the job created by that
`start` invocation, or reports why cleanup could not be confirmed. To verify a
reconciled or otherwise reused job without stopping it on probe failure:

```powershell
& $jobs wait-ready -Id <job-id> -ReadinessUri $readinessUri -ReadinessTimeoutSeconds 30
```

## Provenance

The HTTP readiness workflow adapts Open Mercato's `om-prepare-test-env` under
the MIT License. See
[`references/open-mercato-license.md`](references/open-mercato-license.md).
