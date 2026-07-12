---
name: claude-runner
description: Run Claude Code CLI from Codex with a resume-safe, foreground wrapper for Claude Code, `claude -p`, `/review`, cross-review, rescue/delegation, adversarial review, or interrupted Claude runs. Prefer this over raw `claude` for paid or long-running work so Codex keeps session ids, logs, resume mode, and guardrails explicit.
---

# Claude Runner

Use this skill before running Claude CLI from Codex. Prefer the wrapper because it prints the session id, writes JSONL logs outside the target repository, streams live output, and makes resume mode explicit. The JSONL log and printed session id are the durable handoff; this skill does not provide a job registry, wakeups, or `$cc:*` commands.

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
- Keep normal Claude permissions. Use `-BypassPermissions` only when the caller explicitly authorizes bypass; the wrapper makes that mode conspicuous in its output and invocation.
- Select a documented moving alias with `-ModelAlias fable|haiku|opus|sonnet`, or an exact full model name with `-ExactModel claude-...`. Do not combine them.
- Set effort with the typed `-Effort low|medium|high|xhigh|max` parameter. Do not route effort through `-ClaudeArgs`.
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

Before a paid run, know the repo root, PR number or prompt file, model alias or exact model, effort, session/resume source, log path, and optional budget/turn cap.

## Wrapper

Script: `$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1`

PR review:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1" `
  -WorkingDirectory $repo `
  -ReviewPr $pr `
  -ModelAlias opus `
  -Effort medium `
  -MaxBudgetUsd 10
```

For an exact model selection, use its full Claude model name. If continuing a prior invocation, resume its printed session id:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1" `
  -WorkingDirectory $repo `
  -ReviewPr $pr `
  -ExactModel claude-opus-4-6 `
  -Effort medium `
  -Resume "<printed-session-id>"
```

Resume by id:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1" `
  -WorkingDirectory $repo `
  -ReviewPr $pr `
  -ModelAlias opus `
  -Effort medium `
  -Resume "<printed-session-id>"
```

Resume a PR-linked session without the id:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1" `
  -WorkingDirectory $repo `
  -ReviewPr $pr `
  -ModelAlias opus `
  -Effort medium `
  -FromPr $pr
```

Custom prompt:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1" `
  -WorkingDirectory $repo `
  -PromptFile "$env:TEMP\claude-task.md" `
  -ModelAlias opus `
  -Effort high `
  -MaxTurns 8
```

Explicit permission bypass is exceptional and must be visible at the call site:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$HOME\.codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1" `
  -WorkingDirectory $repo `
  -ReviewPr $pr `
  -ModelAlias opus `
  -Effort medium `
  -BypassPermissions
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

The wrapper writes raw JSONL logs under an external agent-neutral runtime root by default: `AGENT_RUNNER_HOME` when set, otherwise the platform state root (for example, `LOCALAPPDATA\agent-runners` on Windows). It reports the resolved log path without printing the prompt or passthrough argument values. Raw logs may contain Claude events, so treat them as sensitive runtime records and never commit them.

`-DryRun` resolves and reports the invocation without creating the runtime root, log directory, or log file. `-SelfTest` exercises stream rendering without requiring a working directory and also creates nothing. To override log placement deliberately, use `-RuntimeRoot`, `-LogDir`, or `-LogPath`; a relative `-LogDir` or `-LogPath` is resolved from the working directory.

## Regression Tests

The deterministic test harness uses a temporary mock `claude` command and performs no paid work:

```powershell
pwsh ./skills/claude-runner/tests/Invoke-ClaudeRunner.Tests.ps1
```

It covers normal and explicit-bypass permissions, external logs, mutation-free dry-run and self-test behavior, typed effort and model selection, streaming, budgets, interrupted resume, and PR-linked recovery.
