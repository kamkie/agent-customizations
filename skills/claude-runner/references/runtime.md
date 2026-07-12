# Claude Runner Runtime Reference

- [Select a mode](#select-a-mode)
- [Runtime rules](#runtime-rules)
- [Permissions](#permissions)
- [Inputs and controls](#inputs-and-controls)
- [Invocation examples](#invocation-examples)
- [Prompting](#prompting)
- [Sessions, recovery, and logs](#sessions-recovery-and-logs)
- [Regression tests](#regression-tests)

## Select a mode

- PR review/cross-review: `-ReviewPr <number>` from the correct repository root.
- Delegated investigation or implementation: `-PromptFile <path>` with one concise task.
- Resume/follow-up: prefer `-Resume <session-id>`, then `-FromPr <number>` for a PR-linked review, then `-ContinueLatest` only when the working directory identifies the intended session.
- Fresh session: use only when no usable prior session exists or the user explicitly asks.

## Runtime rules

- Run the wrapper in the foreground. If it must outlive the current turn, run the wrapper through `managed-jobs`; do not use raw `Start-Process`, `Start-Job`, `--bg`, `--background`, hidden windows, scheduled tasks, or detached execution.
- Keep session persistence. Do not pass `--no-session-persistence` or use `--fork-session` to continue prior work.
- Use `--output-format stream-json --verbose --include-partial-messages` with `-p`; the wrapper supplies these controls.
- Avoid short timeouts for paid runs. If the runner is alive, wait or read its managed terminal/log.
- Use `-MaxBudgetUsd` or `-MaxTurns` for hard limits.
- Use `-PromptFile` for multiline, XML, or shell-hostile prompts. Keep temporary prompt files outside the repository.
- Do not use `-Bare` for cross-reviews or runs that need `CLAUDE.md`, skills, plugins, hooks, or project settings.
- Pass model, effort, budget, resume source, prompt file, and PR number as typed runtime controls, not task prose or `-ClaudeArgs`.
- Preserve task text except routing controls. Text beginning with `/` remains Claude task text.
- If Claude fails, report the failure and resume command or diagnostic-log path; do not silently replace the delegated run with Codex work.

## Permissions

- Normal Claude permissions are the default.
- `-BypassPermissions` requires explicit authorization and is conspicuous in the invocation and output. It cannot be combined with `-ReviewPr`.
- `-ReviewPr` uses `dontAsk` with a fixed read-only allowlist for file inspection, `gh pr view/diff`, and non-mutating Git inspection. It cannot post reviews, use unrestricted `gh api`, update refs, edit sources, or accept caller-supplied tools.
- For other non-interactive work, use typed `-AllowedTools` rules with the narrowest normal `-PermissionMode`. `acceptEdits` does not authorize arbitrary build, Git, or GitHub commands.
- Add a mutation rule only when that exact mutation is authorized. Otherwise, let Codex record Claude's returned verdict.

## Inputs and controls

Resolve the requested repository rather than hard-coding paths, PR numbers, or session IDs:

```powershell
$runner = Join-Path $HOME ".codex\skills\claude-runner\scripts\Invoke-ClaudeRunner.ps1"
$repo = git rev-parse --show-toplevel 2>$null
if ([string]::IsNullOrWhiteSpace($repo)) { $repo = (Get-Location).Path }
$pr = <pr-number>
```

Before a paid run, identify the repository, task or PR, model, effort, session/resume source, Claude configuration directory, diagnostic log, permission profile, and optional limits.

- Moving model alias: `-ModelAlias fable|haiku|opus|sonnet`.
- Exact model: `-ExactModel claude-...`. Do not combine it with `-ModelAlias`.
- Effort: `-Effort low|medium|high|xhigh|max`.
- Limits: `-MaxBudgetUsd <decimal>` and `-MaxTurns <int>`.

## Invocation examples

PR review:

```powershell
& $runner -WorkingDirectory $repo -ReviewPr $pr -ModelAlias opus -Effort medium -MaxBudgetUsd 10
```

Resume by native session id:

```powershell
& $runner -WorkingDirectory $repo -ReviewPr $pr -ModelAlias opus -Effort medium -Resume "<printed-session-id>"
```

Resume a PR-linked session when the id is unavailable:

```powershell
& $runner -WorkingDirectory $repo -ReviewPr $pr -ModelAlias opus -Effort medium -FromPr $pr
```

Use an exact model:

```powershell
& $runner -WorkingDirectory $repo -ReviewPr $pr -ExactModel claude-opus-4-6 -Effort medium
```

Custom task:

```powershell
& $runner -WorkingDirectory $repo -PromptFile "$env:TEMP\claude-task.md" -ModelAlias opus -Effort high -MaxTurns 8
```

Exceptional explicit bypass for a non-review task:

```powershell
& $runner -WorkingDirectory $repo -Prompt "Run the authorized task" -ModelAlias opus -Effort medium -BypassPermissions
```

## Prompting

Use one clear task per run, define done, and include only relevant constraints. Plain text is enough for `/review <pr>` or a simple task. For complex custom prompts, use the optional blocks in [claude-prompt-blocks.md](claude-prompt-blocks.md).

For a resumed follow-up, send only the delta instruction unless the task changed materially.

## Sessions, recovery, and logs

Claude Code owns the canonical transcript under `CLAUDE_CONFIG_DIR\projects`, or `~/.claude/projects` when the variable is unset. The wrapper keeps persistence enabled and prints the native session id and directory. Resume with this wrapper or `claude --resume <session-id>`.

Claude Code CLI and Claude Desktop keep separate histories. Use Claude Code's `/desktop` command when an interactive CLI session must move into Desktop. Codex imports and continuity must use supported native artifacts, not the wrapper's raw diagnostic stream.

After an interruption:

1. Check whether `claude` is still running.
2. If it is running, wait or read the attached/managed output; do not kill it.
3. If it exited without the result, use `-Resume`, `-FromPr`, or `-ContinueLatest`.
4. Start fresh only when no session exists or the user explicitly asks.

The separate diagnostic JSONL defaults to `CLAUDE_CONFIG_DIR\logs\claude-runner`, or `~/.claude/logs/claude-runner`. Its reported summary omits prompts, allowlist contents, and passthrough values. Raw events can still be sensitive; never commit the log.

`-DryRun` reports the invocation without creating configuration or log paths. `-SelfTest` exercises rendering without a working directory and creates nothing. Tests may use `-ClaudeConfigDirectory`; intentional log overrides use `-LogDir` or `-LogPath`, resolved relative to the working directory when needed.

## Regression tests

The deterministic mock harness performs no paid work:

```powershell
pwsh ./skills/claude-runner/tests/Invoke-ClaudeRunner.Tests.ps1
```

It covers default and bypass permissions, the read-only review profile, diagnostic placement, mutation-free dry-run/self-test, typed model and effort controls, streaming, budgets, interrupted resume, and PR-linked recovery.
