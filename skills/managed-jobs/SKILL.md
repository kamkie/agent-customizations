---
name: managed-jobs
description: Run, inspect, recover, and stop long-running local processes with durable state and logs across agent restarts; visible Windows Terminal output is opt-in.
---

# Managed Jobs

Use `scripts/Invoke-ManagedJob.ps1` from this installed skill directory. It
locates companion scripts relative to itself under either Codex or Claude.

## State

State-root precedence is `-StateRoot`, `MANAGED_JOBS_ROOT`, then
`$HOME/.agent-customizations/managed-jobs`. Set the same environment value when
agents should share a registry. Agent-specific registries are not discovered.

## Start

```powershell
& $jobs start -Name api -Executable dotnet -Arguments @('run') -WorkingDirectory $repo
```

Hidden durable execution is the default. Add `-Visible` only when the user asks
for a shared terminal, and `-KeepTerminalOpen` only when it should remain open.

Treat names, paths, arguments, environment entries, records, and logs as
non-secret. Inherit secrets from the parent process or use standard input,
response files, or credential stores. The controller rejects likely secrets;
permanent records omit argument text and environment values, while the
short-lived launch file is deleted when claimed. Child output is logged verbatim.

Equivalent active invocations are rejected using a stable fingerprint and a
serialized pre-launch check. Record the returned job id.

## Inspect

```powershell
& $jobs reconcile
& $jobs list -Status running,starting -Json
& $jobs status -Id <job-id>
& $jobs status -Status orphaned -Json
& $jobs logs -Id <job-id> -Tail 100
& $jobs logs -Id <job-id> -Follow
```

Reconcile after an agent restart. Structured status includes the expected
PID/start time, current snapshot when relevant, and identity match result.

## Stop and prune

```powershell
& $jobs stop -Id <job-id>
& $jobs prune -OlderThanDays 14 -WhatIf
& $jobs prune -OlderThanDays 14 -Status completed,failed,stopped,orphaned
```

Stop verifies PID and creation time before terminating the process tree. Prune
excludes active and invalid records and removes only managed records and logs.

## Boundaries

- Keep short commands attached to the active agent tool call.
- Do not directly use detached processes, jobs, terminal tabs, or background
  flags for long-lived work.
- Use `claude-runner` for Claude session, resume, budget, and review behavior.
- Logs merge stdout and stderr; use application-native structured logs when
  stream separation matters.
