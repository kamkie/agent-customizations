---
name: claude-runner
description: Run Claude Code CLI from Codex with a resume-safe, foreground wrapper for Claude Code, `claude -p`, `/review`, cross-review, rescue/delegation, adversarial review, or interrupted Claude runs. Prefer this over raw `claude` for paid or long-running work so Codex keeps session ids, logs, resume mode, and guardrails explicit.
---

# Claude Runner

Use this skill before running Claude CLI from Codex. Prefer the wrapper because it prints the session id, writes JSONL logs, streams live output, and makes resume mode explicit. The JSONL log and printed session id are the durable handoff; this skill does not provide a job registry, wakeups, or `$cc:*` commands.

## Mode

- PR review/cross-review: `-ReviewPr <number>` from the correct repo root.
- Delegated investigation or implementation: `-PromptFile <path>` with one concise task.
- Resume/follow-up: use `-Resume <session-id>` if known, else `-FromPr <number>` for PR-linked review sessions, else `-ContinueLatest` only when the cwd clearly identifies the intended latest Claude session.
- Fresh session: start one only when no usable prior session exists or the user explicitly asks.

## Rules

- Run Claude attached to the active terminal/session. Do not use `Start-Process`, `Start-Job`, `--bg`, `--background`, hidden windows, scheduled tasks, or detached execution unless explicitly asked.
- Keep session persistence. Do not pass `--no-session-persistence`; never use `--fork-session` to continue prior work.
- Resume interrupted work instead of rerunning a bare `claude ... -p "<same prompt>"`.
- For live non-interactive output, use `--output-format stream-json --verbose --include-partial-messages` with `-p`.
- Avoid short timeouts for paid runs. If the runner is still alive, wait or attach/read the active terminal.
- Use `-MaxBudgetUsd` or `-MaxTurns` when the caller wants hard cost or turn limits.
- Use `-PromptFile` for multiline prompts, XML prompts, or shell-hostile quoting. Keep temporary prompt files outside the repo.
- Do not use `-Bare` for cross-reviews or runs that must load `CLAUDE.md`, skills, plugins, hooks, or project settings; reserve it for deterministic CI/script calls.
- Treat model, budget, resume, prompt-file, and PR number as runtime controls, not natural-language task text.
- Preserve the user's task text except for removing routing controls. If it begins with `/`, pass it as Claude task text.
- Do not convert a failed Claude invocation into Codex doing the delegated work inline. Surface the failure plus the resume command or log path.

## Resolve Inputs

Do not hard-code repo paths, PR numbers, or session IDs in reusable prompts. Before invoking the wrapper, resolve the repo root requested by the user:

```powershell
$runner = Join-Path $HOME ".codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1"
$repo = (git rev-parse --show-toplevel 2>$null)
if ([string]::IsNullOrWhiteSpace($repo)) { $repo = (Get-Location).Path }
$pr = <pr-number>
```

Before a paid run, know the repo root, PR number or prompt file, model, session/resume source, log path, and optional budget/turn cap.

## Wrapper

Script: `$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1`

PR review:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1" `
  -WorkingDirectory $repo `
  -ReviewPr $pr `
  -Model fable `
  -MaxBudgetUsd 10
```

If Fable is quota-blocked before useful work starts, rerun intentionally with Opus and reuse the printed session id if one exists:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1" `
  -WorkingDirectory $repo `
  -ReviewPr $pr `
  -Model opus `
  -SessionId "<printed-session-id>"
```

Resume by id:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1" `
  -WorkingDirectory $repo `
  -ReviewPr $pr `
  -Model opus `
  -Resume "<printed-session-id>"
```

Resume a PR-linked session without the id:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1" `
  -WorkingDirectory $repo `
  -ReviewPr $pr `
  -Model opus `
  -FromPr $pr
```

Custom prompt:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1" `
  -WorkingDirectory $repo `
  -PromptFile "$env:TEMP\claude-task.md" `
  -Model opus `
  -MaxTurns 8
```

## Prompting Claude

For custom tasks, use one clear task per run, define done, and add only relevant constraints. Use XML tags such as `<instructions>`, `<context>`, `<input>`, `<constraints>`, and `<output_format>` only for prompts more complex than `/review <pr>` or a plain sentence.

Example:

```xml
<instructions>
Review the requested PR or branch for correctness regressions in the named component only.
</instructions>
<context>
Use repository files, diffs, and command output as evidence. Do not guess missing facts.
</context>
<constraints>
Ground claims in files, diffs, or command output. Label hypotheses as hypotheses.
</constraints>
<output_format>
Return findings first, ordered by severity. Include file paths and line numbers. If there are no findings, say so.
</output_format>
```

For resume follow-ups, resume the session and send only the delta instruction unless the task changed materially. Before composing a long custom prompt, read [references/claude-prompt-blocks.md](references/claude-prompt-blocks.md).

## Interruptions And Logs

When a Claude run times out or the terminal is interrupted:

1. Check whether `claude` is still running.
2. If running, do not kill it; let it finish or attach/read the active terminal.
3. If exited without the required result, rerun with `-Resume <session-id>`, `-FromPr <pr>`, or `-ContinueLatest`.
4. Start fresh only if no session was created or the user explicitly asks.

The wrapper writes raw JSONL logs under `.logs` in the working directory by default. Keep the log path when reporting review results or diagnosing failures.
