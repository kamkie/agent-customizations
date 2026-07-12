# Managed Jobs Operations

## State

State-root precedence is `-StateRoot`, `MANAGED_JOBS_ROOT`, then
`$HOME/.agent-customizations/managed-jobs`. Set the same environment value when
Codex and Claude should share a registry. Agent-specific registries are not
discovered.

## Start

```powershell
& $jobs start -Name api -Executable dotnet -Arguments @('run') -WorkingDirectory $repo
```

Hidden durable execution is the default. Add `-Visible` only when the user asks
for a shared terminal, and `-KeepTerminalOpen` only when it should remain open.

Equivalent active invocations are rejected using a stable fingerprint and a
serialized pre-launch check. Record the returned job id.

## Secret boundary

Treat names, paths, arguments, environment entries, records, and logs as
non-secret. Inherit secrets from the parent process or use standard input,
response files, or credential stores. The controller rejects likely secrets.

Permanent records omit argument text and environment values. A short-lived
launch file carries validated non-secret values and is deleted when claimed.
Child output is logged verbatim. Logs merge stdout and stderr; use
application-native structured logs when stream separation matters.

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
PID/start time, current snapshot when relevant, and identity-match result.

## Stop and prune

```powershell
& $jobs stop -Id <job-id>
& $jobs prune -OlderThanDays 14 -WhatIf
& $jobs prune -OlderThanDays 14 -Status completed,failed,stopped,orphaned
```

Stop verifies PID and creation time before terminating the process tree. Never
stop a process whose identity does not match the record. Preview pruning first;
prune excludes active and invalid records and removes only managed records and
logs.
