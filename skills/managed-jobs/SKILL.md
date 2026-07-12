---
name: managed-jobs
description: Run, observe, recover, and stop long-running local processes with durable state and logs across agent restarts. Use for dev servers, watchers, lengthy builds or tests, paid CLI agents, or any process expected to outlive a turn; use visible Windows Terminal mode only when the user asks to watch the same live output.
---

# Managed Jobs

Use `scripts/Invoke-ManagedJob.ps1` from this installed skill directory. The
controller locates all companion scripts relative to itself, so the same skill
copy works under either `<CODEX_HOME>/skills/managed-jobs` or
`<CLAUDE_CONFIG_DIR>/skills/managed-jobs`; a Claude-only installation does not
depend on Codex files.

```powershell
$jobs = Join-Path $managedJobsSkillDirectory 'scripts\Invoke-ManagedJob.ps1'
```

`$managedJobsSkillDirectory` means the directory containing this `SKILL.md`, as
resolved by the agent that loaded the skill. Do not hard-code another agent's
home directory.

## State root and compatibility

The registry is agent-neutral. Resolution order is:

1. `-StateRoot` for one invocation;
2. `MANAGED_JOBS_ROOT` for a deliberately shared installation;
3. an existing legacy `<CODEX_HOME>/managed-jobs` registry when the new default
   does not exist;
4. the new default, `$HOME/.agent-customizations/managed-jobs`.

Set the same `MANAGED_JOBS_ROOT` for Codex and Claude when they should share one
registry. New records written through a legacy fallback use the safe schema;
existing records remain readable in place, without an implicit copy, deletion,
or live-install mutation. Choose an explicit state root before creating new jobs
if multiple legacy registries need manual consolidation.

## Secret boundary

Treat names, executable paths, working directories, arguments, environment
entries, records, and logs as non-secret metadata. Never put credentials in a
job name, argument, working directory, or `-Environment` value. Let secrets be
inherited from the already configured parent process, read them from standard
input or an access-controlled response file, or use the target tool's credential
store.

The controller rejects secret-like option names, credential-bearing URLs, and
secret-like `-Environment` keys. Permanent schema-v2 records contain only the
argument count and environment variable names, never argument text or
environment values. A short-lived launch file carries validated non-secret
values to the host and is deleted when claimed. Controller-generated log lines
omit arguments and environment. Child-process output is recorded verbatim, so
configure application-native redaction and never print secrets to stdout or
stderr.

## Start

Default to a hidden durable host with a persistent combined log:

```powershell
& $jobs start -Name api -Executable dotnet -Arguments @('run') -WorkingDirectory $repo
```

When the user explicitly asks for a visible/shared terminal, add `-Visible`.
The Windows Terminal tab and durable log show the same output. Use
`-KeepTerminalOpen` only when the user wants the tab to remain after completion.

Each start computes a stable SHA-256 fingerprint from the executable, arguments,
normalized working directory, and environment variable names. Launch locking
checks active records before creating a host; an equivalent `starting` or
`running` job is rejected with its existing job id. Environment values are
intentionally excluded so changing a value cannot bypass conservative duplicate
detection.

## Inspect and recover

```powershell
& $jobs reconcile
& $jobs reconcile -Status orphaned
& $jobs list
& $jobs list -Status running,starting -Json
& $jobs status -Id <job-id>
& $jobs status -Status orphaned -Json
& $jobs logs -Id <job-id> -Tail 100
& $jobs logs -Id <job-id> -Follow
```

Run `reconcile` after an agent restart. `list -Json`, filtered `status`, and
`reconcile` return structured JSON without requiring table parsing. Status
records include `processIdentity` with the expected PID/start time, the current
snapshot when present, and whether they match. A job becomes `orphaned` only
when its recorded host identity no longer exists and no terminal state was
recorded.

## Stop and prune

```powershell
& $jobs stop -Id <job-id>
& $jobs prune -OlderThanDays 14 -WhatIf
& $jobs prune -OlderThanDays 14 -Status completed,failed,stopped,orphaned
```

`stop` verifies both recorded PID and process creation time before terminating
the tree. Never bypass that check with ad hoc PID killing. `prune -WhatIf`
returns the exact candidates without deleting them. Pruning excludes active and
invalid records and removes only the record plus the log path derived from that
record's validated id inside the selected state root.

## Claude

Continue using the `claude-runner` skill for Claude session ids, JSONL output,
budget controls, and resume semantics. Wrap only genuinely long-lived Claude
invocations here when restart survival is requested, and preserve the Claude
session id in the job name or task handoff.

## Boundaries

- Keep ordinary short commands attached to the active agent tool call.
- Do not use `Start-Process`, `Start-Job`, detached Windows Terminal tabs, or
  background switches directly for long-lived work.
- Logs merge stdout and stderr in arrival order. Use application-native
  structured logs when exact stream separation matters.
- Visible mode is optional and Windows-only; hidden durable mode is the default.
