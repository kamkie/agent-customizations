---
name: claude-runner
description: Run or resume Claude Code from Codex with explicit sessions and permissions. Use for `claude -p`, reviews, delegation, rescue, or interrupted runs.
---

# Claude Runner

Use `scripts/Invoke-ClaudeRunner.ps1`; it preserves Claude Code's native session and writes separate diagnostics outside target repositories.

```powershell
$runner = Join-Path $HOME ".codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1"
& $runner -WorkingDirectory $repo -ReviewPr $pr -ModelAlias opus -Effort medium
```

- Resume existing sessions instead of repeating paid work.
- Keep normal permissions; bypass only with explicit authorization. `-ReviewPr` is read-only.
- Keep the wrapper attached; use `managed-jobs` when the process must survive a turn or restart.

Read [the runtime reference](references/runtime.md) for other modes, controls, examples, recovery, sessions, logs, and tests. Read [the prompt blocks](references/claude-prompt-blocks.md) only for complex custom prompts.
