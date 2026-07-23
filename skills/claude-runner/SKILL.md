---
name: claude-runner
description: Run or resume Claude Code CLI from Codex with explicit sessions, permissions, logs, and recovery. Use for `claude -p`, PR reviews, explicit Claude delegation or rescue, and interrupted Claude sessions. Do not use for ordinary Codex or subagent delegation, generic process recovery, or non-Claude tasks.
---

# Claude Runner

Use `scripts/Invoke-ClaudeRunner.ps1`; it preserves Claude Code's native session
and writes separate diagnostics outside target repositories.

## Happy path

```powershell
$runner = Join-Path $claudeRunnerSkillDirectory 'scripts\Invoke-ClaudeRunner.ps1'
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    throw 'Install and authenticate Claude Code CLI before a live run.'
}
$repo = git rev-parse --show-toplevel 2>$null
if ([string]::IsNullOrWhiteSpace($repo)) { throw 'Run from the target repository.' }
$pr = [int]'<requested-pr-number>'
& $runner -WorkingDirectory $repo -ReviewPr $pr -ModelAlias opus -Effort medium
```

- Resolve `$claudeRunnerSkillDirectory` to this `SKILL.md` file's directory.
- To continue, append `-Resume "<session-id>"`; if that id is unavailable for the same PR, append `-FromPr $pr`.
- Keep normal permissions; bypass only with explicit authorization. `-ReviewPr` is read-only.
- Never pass `-MaxBudgetUsd` or `-MaxTurns`. Codex must not estimate or impose
  budget or turn caps on Claude runs.
- Keep the wrapper attached; use `managed-jobs` when the process must survive a turn or restart.
- Report the exit status, verdict or findings, printed native session id,
  diagnostic-log path, and exact resume option when further work is needed.

Read [the runtime reference](references/runtime.md) for other modes, controls, examples, recovery, sessions, logs, and tests. Read [the prompt blocks](references/claude-prompt-blocks.md) only for complex custom prompts.
