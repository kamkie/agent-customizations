# Managed Jobs Operations

## State

State-root precedence is `-StateRoot`, `MANAGED_JOBS_ROOT`, then
`$HOME/.agent-customizations/managed-jobs`. Set the same environment value when
Codex and Claude should share a registry. Agent-specific registries are not
discovered. Turn and session lifetimes must use the root visible to the
cleanup hooks: set `MANAGED_JOBS_ROOT` before starting the agent when
overriding the default. The controller rejects a different one-off
`-StateRoot` for those automatic lifetimes; persistent jobs may use one.

## Process lifetime

Every new record declares one lifetime:

- `Turn`: stop automatically when the owning agent finishes the current turn.
- `Session`: allow use across turns, then stop when the owning session ends.
- `Persistent`: keep running until explicitly stopped; always hand it off.

`Auto` is the controller default. In the Codex installation, when
`CODEX_THREAD_ID` is available, `Auto` records Codex ownership and resolves to
`Turn`. In the Claude Code installation, when `CLAUDE_CODE_SESSION_ID` is
available, `Auto` records Claude ownership and resolves to `Turn`. Each
installation adopts only its own identity, so a Claude launch nested inside
Codex, or the reverse, never claims the outer agent's session. Without an
integrated owner, `Auto` retains the previous `Persistent` behavior.
Target-specific cleanup hooks must supply an agent and session identifier; they
never act on unowned or differently owned records.

Turn and session jobs maintain hashed owner references while active. Cleanup
uses only those references; it does not scan or reconcile unrelated records.

The Windows host assigns itself and its descendants to a kill-on-close Job
Object before launching the child. If the host exits or crashes, Windows
terminates descendants that would otherwise escape as live orphan processes.

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

Turn and session cleanup is silent when it succeeds. A turn is blocked only
when an owned process tree cannot be stopped safely; the hook names the job,
PID, and failure. Dead processes and stale records are reconciled without
injecting context into another conversation.

The Codex registrations follow the current
[Codex hook contract](https://learn.chatgpt.com/docs/hooks): shell calls match
`Bash`, `PreToolUse` uses `permissionDecision`, and a `Stop`
`decision: "block"` continues the turn. `stop_hook_active` bounds cleanup
failures to one continuation before a clear warning lets the turn end.

The Claude Code registrations follow the same shapes under the
[Claude Code hooks contract](https://docs.claude.com/en/docs/claude-code/hooks):
handlers carry only `type`, `command`, and `timeout`, and the cleanup hooks
prefer the payload `session_id` over an inherited `CLAUDE_CODE_SESSION_ID` so a
nested session never cleans its parent's jobs. Turn cleanup also registers on
`StopFailure`, the side-effect-only event Claude fires when an API error ends
the turn; a user interrupt fires neither event, so an interrupted turn's jobs
are swept at the next turn's `Stop` or at `SessionEnd`.

## Identity and prune

```powershell
& $jobs prune -OlderThanDays 14 -WhatIf
& $jobs prune -OlderThanDays 14 -Status completed,failed,stopped,orphaned
```

Stop verifies PID and creation time before terminating the process tree. Never
stop a process whose identity does not match the record. Preview pruning first;
prune excludes active and invalid records and removes only managed records and
logs.
