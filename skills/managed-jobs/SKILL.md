---
name: managed-jobs
description: Run, observe, recover, and stop long-running local processes with durable state and logs across Codex restarts. Use for dev servers, watchers, lengthy builds or tests, paid CLI agents, or any process expected to outlive a turn; use visible Windows Terminal mode only when the user asks to watch the same live output.
---

# Managed Jobs

Use the bundled PowerShell controller instead of raw detached process launches.

```powershell
$jobs = Join-Path $HOME '.codex\skills\managed-jobs\scripts\Invoke-ManagedJob.ps1'
```

## Start

Default to a hidden durable host with a persistent combined log:

```powershell
& $jobs start -Name api -Executable dotnet -Arguments @('run') -WorkingDirectory $repo
```

When the user explicitly asks for a visible/shared terminal, add `-Visible`. The Windows Terminal tab and the durable log show the same output:

```powershell
& $jobs start -Name api -Executable dotnet -Arguments @('run') -WorkingDirectory $repo -Visible
```

Use `-KeepTerminalOpen` only when the user wants the tab to remain after completion. Pass environment variables with `-Environment @{ NAME = 'value' }`.

Do not pass secrets through `-Environment`, because job launch metadata is persisted locally. Let secret-bearing values inherit from the already configured parent environment or use the target tool's credential store.

Record the returned job id. Do not launch an equivalent second process if a matching managed job is already running.

## Inspect and recover

```powershell
& $jobs reconcile
& $jobs list
& $jobs status -Id <job-id>
& $jobs logs -Id <job-id> -Tail 100
& $jobs logs -Id <job-id> -Follow
```

Run `reconcile` after a Codex restart. A job is `orphaned` when its recorded host no longer exists and it did not record a terminal status.

## Stop and prune

```powershell
& $jobs stop -Id <job-id>
& $jobs prune -OlderThanDays 14
```

`stop` verifies the recorded process creation time before terminating its process tree. Never bypass that check with ad hoc PID killing. `prune` removes only terminal-state registry entries and their logs.

## Claude

Continue using the `claude-runner` skill for Claude session ids, JSONL output, budget controls, and resume semantics. Wrap only genuinely long-lived Claude invocations here when restart survival is requested, and preserve the Claude session id in the job name or task handoff.

## Boundaries

- Keep ordinary short commands attached to the active Codex tool call.
- Do not use `Start-Process`, `Start-Job`, detached Windows Terminal tabs, or background switches directly for long-lived work.
- Logs merge stdout and stderr in arrival order. Use application-native structured logs when exact stream separation matters.
- Visible mode is optional and Windows-only; hidden durable mode is the default.
