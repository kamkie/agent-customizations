# Managed Jobs Operations

## State

State-root precedence is `-StateRoot`, `MANAGED_JOBS_ROOT`, then
`$HOME/.agent-customizations/managed-jobs`. Set the same environment value when
Codex and Claude should share a registry. Agent-specific registries are not
discovered.

The session-start hook stores the last reported active and orphaned job sets in
the state root. It emits context only when the corresponding set changes, and
orphan context is informational rather than an instruction to inspect unrelated
work.

## Visible execution

Use the `$jobs` and `$repo` values resolved by `SKILL.md`:

```powershell
& $jobs start -Name api -Executable dotnet -Arguments @('run') -WorkingDirectory $repo -Visible
```

Add `-KeepTerminalOpen` only when the user wants the terminal to remain open
after completion. The user must close that terminal manually; `stop` manages
active jobs and does not close a kept-open terminal after its job is complete.

## Duplicate detection

Equivalent active invocations are rejected using a stable fingerprint under a
serialized pre-launch check.

## Secret boundary

Inherit secrets from the parent process or use standard input, response files,
or credential stores. The controller rejects likely secrets.

Permanent records omit argument text and environment values. A short-lived
launch file carries validated non-secret values and is deleted when claimed.
Child output is logged verbatim. Logs merge stdout and stderr; use
application-native structured logs when stream separation matters.

## Structured recovery

```powershell
& $jobs status -Status orphaned -Json
& $jobs logs -Id <job-id> -Follow
```

Structured status includes the expected PID/start time, current snapshot when
relevant, and identity-match result.

## Identity and prune

```powershell
& $jobs prune -OlderThanDays 14 -WhatIf
& $jobs prune -OlderThanDays 14 -Status completed,failed,stopped,orphaned
```

Stop verifies PID and creation time before terminating the process tree. Never
stop a process whose identity does not match the record. Preview pruning first;
prune excludes active and invalid records and removes only managed records and
logs.
