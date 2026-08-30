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

### Shared terminal

Add `-SharedTerminal` only with `-Visible` when both the user and agent need the
same managed pane. Shared mode resolves `wtcli.exe` directly from
the installed `Microsoft.IntelligentTerminal` Store package (version
0.2.2192.0 or newer); it does not trust a PATH alias. The in-pane host records
its `WT_SESSION` and `WT_COM_CLSID` in the job's separate local control file.
Those identifiers are never returned by `start` or `status` and are never
written to the ordinary managed log.

If that exact package already has a live protocol-registered window, shared
launch uses its packaged `wtcli new-tab` protocol path. Version 0.2 creates
protocol tabs in the background, so the user's foreground window and active
pane remain unchanged. The new tab uses the visible PowerShell Core profile
discovered from the terminal's current settings, so renamed profiles retain
their icon and terminal settings while the managed command remains `pwsh.exe`.
Selection uses the profile GUID when available and its discovered name when the
settings payload omits a GUID and that name is unique and option-safe. If the
profile or an unambiguous selector is unavailable, launch falls back to the
default profile instead of failing. The controller verifies the returned
session id against the session registered by the managed host. With no live
window,
shared launch shell-activates the packaged app, which opens a new foreground
window, waits for that window to register with the terminal protocol, and then
creates the managed tab through the same verified `wtcli new-tab` path.
`wtai.exe` is not used: on recent package versions it silently fails to open a
window, and a window it does open is not protocol-registered. Add
`-RequireBackgroundTab` to reject the focus-taking cold start when focus
preservation is mandatory.

Process-level signals such as the main window handle are unreliable for
`WindowsTerminal.exe`, so the controller never guesses whether an existing
package process is live and never stops one. When the protocol reports no
window, cold start shell-activates the app regardless of leftover processes;
if no registered window appears before the bootstrap deadline, the launch
fails with the leftover process ids so the user can close or stop them
deliberately.

The controller accepts only the managed job id. `capture`, `send-input`, and
`send-key` load and validate that job's host identity, Job Object containment,
and registered control file before invoking the packaged CLI. They never accept
an arbitrary pane id or use the focused pane. Capture is limited to 1-500 lines.
Literal input is passed without shell interpretation, and named keys are limited
to `Enter`, `Tab`, `Escape`, `Backspace`, and `Ctrl+C`. The managed host consumes
Ctrl+C only for itself, allowing the foreground child to receive the interrupt
while the host remains alive to publish the child's terminal result.

Pane content is sensitive. Do not store captures or paste them into ordinary
logs. Never send credentials with `send-input`; leave an authentication prompt
visible for the user to answer directly, and do not poll capture while that
secret prompt is waiting. Resume capture only after the user says the secret
entry is complete.

Normal completion, explicit stop, turn/session cleanup, failed launch, prune,
and orphan reconciliation remove the job-scoped control file. Control metadata
does not survive as a general pane registry.

Run the focused integration test on a desktop session where visible Windows
Terminal windows are allowed:

```powershell
pwsh ./skills/managed-jobs/tests/ManagedJobs.SharedTerminal.Tests.ps1
# The default run skips if no live window exists, so it never cold-starts into focus.
# Add -AllowForegroundBootstrap only for an explicitly attended cold-start run.
# Add -RequireUserInput to verify direct non-secret user typing after selecting the background tab.
```

## Duplicate detection

Equivalent active invocations are rejected using a stable fingerprint under a
serialized pre-launch check.

## HTTP readiness

`start -ReadinessUri <uri>` and `wait-ready` poll a credential-free loopback
HTTP(S) URL until it returns a status from 200 through 399. Redirects count as
ready but are not followed, and the probe bypasses configured proxies. The
controller confirms the managed job is still active after the response. Each
result reports the URL, status code, attempt count, check time, and elapsed
milliseconds.

Each individual probe has a response budget of at most two seconds, clamped to
the time remaining before the overall readiness deadline, so an unresponsive
endpoint cannot consume an extra probe budget. Use a fast health endpoint whose
response does not trigger application startup work.
HTTPS probes use normal certificate validation, so trust the service's local
development certificate before relying on an HTTPS readiness URL.

The HTTP response proves that a service is listening at the URL, not that the
managed process owns that socket. Use a task-specific free port and reconcile
or stop stale jobs before starting a replacement service.

A failed readiness gate on `start` stops only the job created by that
invocation and records the reason. A failed `wait-ready` leaves the existing
job unchanged because it may be shared or intentionally persistent. Readiness
evidence is returned to the caller rather than stored in the permanent job
record. A failed `start` stores only a generic readiness-gate reason; its thrown
error includes the probe URL and managed log path for diagnosis. Keep the whole
readiness URL, including its path, non-secret. Hand successful evidence off with
the job id and log path when downstream work depends on the service.

## Secret boundary

Inherit secrets from the parent process or use standard input, response files,
or credential stores. The controller rejects likely secrets.

Permanent records omit argument text and environment values. A short-lived
launch file carries validated non-secret values and is deleted when claimed.
Hidden and ordinary visible child output is logged verbatim. Shared-terminal
children inherit the pane streams directly so interactive prompts and terminal
control sequences remain intact; their ordinary managed log contains lifecycle
headers and footers, while pane output is captured only on demand through the
job-scoped controller. Logs merge stdout and stderr; use application-native
structured logs when stream separation matters.

## Structured recovery

```powershell
& $jobs status -Status orphaned -Json
& $jobs logs -Id <job-id> -Follow
```

Normal `start`, `list`, and collection `status` calls reconcile records whose
stored state is `starting` or `running`; they do not repair inactive historical
records. On session startup or resume, the installed `SessionStart` hook
automatically runs reconciliation in its native asynchronous handler, so
inactive owner references and shared-terminal control records are repaired
without blocking launches or depending on agent memory. Use explicit
reconciliation only to retry a reported hook failure or request an additional
repair. Prefer `status -Id <job-id>` when the caller already has the returned job
id because it reads and reconciles only that record.

Structured status includes the expected PID/start time, current snapshot when
relevant, and identity-match result.

### Maintenance operations

`reconcile -Async` and `prune -Async` start hidden persistent jobs whose
`kind` is `maintenance`. The returned record uses the normal managed-job
contract: inspect it with `status -Id`, read its JSON result with `logs -Id`,
and stop it through the controller if cancellation is explicitly requested.
An exclusive maintenance lock permits only one reconcile or prune mutation at
a time; an overlapping operation fails without doing partial work.

Codex and Claude Code register the reconciliation scheduler as an asynchronous
`SessionStart` command hook for `startup|resume`. The hook performs full
reconciliation in its background command process, so the agent continues
immediately without spawning an unmanaged child. If another maintenance
operation owns the lock, the hook fails fast and reports the skipped attempt;
the next startup or resume retries without depending on agent memory. The hook
runtime is bounded to ten minutes. Turn and session cleanup remain separate
targeted hook operations over owner references. Manual `reconcile -Async` keeps
the supervised persistent-job contract described above. Its worker retries lock
contention in the background so an accepted maintenance job completes later
without slowing the caller or changing SessionStart's fail-fast behavior.

Async prune snapshots its candidate ids and cutoff into a one-time runtime plan
before dispatch. The worker consumes that plan under the maintenance lock,
rechecks that every planned record still exists, is terminal, matches the
selected status filter, and remains older than the frozen cutoff, then reports
removed and skipped ids in its log. It cannot discover or delete records that
were not in the plan. Preview with synchronous `prune -WhatIf` first; `-Async`
cannot be combined with `-WhatIf`.

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

Stop verifies PID, creation time, and confirmed Job Object containment before
terminating the managed host. Closing the host's kill-on-close Job Object stops
its descendants. Never stop a process whose identity does not match the record.
Preview pruning first; prune excludes active and invalid records and removes
only managed records and logs.
