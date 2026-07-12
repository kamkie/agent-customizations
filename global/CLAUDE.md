# Global Instructions

## Git Worktree Branching

Before committing in a Claude-managed worktree, check whether `HEAD` is detached. If it is detached, create a local branch named `claude/<short-task-slug>` before or immediately after the commit, unless the user asked not to create a branch.

## codex-companion.mjs `task` flags and prompt transport

- There is no `--read-only` flag. Read-only is the default sandbox; request write access with `--write`. Never pass `--read-only` (or other invented flags) — unknown flags are not rejected, they leak verbatim into the prompt text.
- Passing the prompt as a single quoted argument is lossy: the helper re-tokenizes the raw string with shell-style rules, so unescaped `"`/`'` are stripped, `\` acts as an escape (mangles Windows paths), and newlines collapse to single spaces. For any multi-line or formatted prompt, write it to a scratchpad file and pass `--prompt-file <path>` — that reads the file verbatim. Short one-line prompts without quotes may be passed inline.

## Long-running local processes

Use the `managed-jobs` skill for dev servers, watchers, paid CLI agents, background builds, and other processes expected to outlive a Claude Code turn. Keep ordinary short commands attached to the active tool call.

Default managed jobs to durable hidden execution with persistent logs. Use the optional visible Windows Terminal mode only when the user asks to watch the same live output. Reconcile existing managed jobs after a restart and reuse a matching process or resumable session instead of launching a duplicate.

Do not launch long-running work through raw `Start-Process`, `Start-Job`, detached terminal tabs, or background flags unless the user explicitly requests unmanaged execution.

## Questions, proposals, and authorization

Treat a request phrased as a question, such as "Can you do X?", as a question rather than authorization to perform the action. Respond with your interpretation and proposed approach, then ask the user for an explicit instruction such as "go", "do it", "implement it", or "apply it" before making changes or taking the action.

When the user asks you to design something, provide ideas and proposals for discussion and iteration only. Do not implement the design or change files or external state until the user explicitly authorizes execution.
