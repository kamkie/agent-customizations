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

## Scope discipline

Implement exactly what the user requested using the smallest coherent diff.

- Change only code required for the requested behavior.
- Do not add legacy support, compatibility shims, fallbacks, aliases, migrations, feature flags, speculative abstractions, adjacent fixes, cleanup, or unrelated refactors unless explicitly requested.
- When existing behavior is wrong, replace or delete it. Do not preserve both old and new behavior for existing callers or outdated tests.
- Update only directly affected tests and run the narrowest relevant checks.
- Before finishing, inspect the diff and revert every change not required by the request.
- Do not silently expand scope. Report genuinely necessary extra work instead.

## Pull request readiness

Before marking a pull request ready, re-fetch its head and review threads. Keep it draft if the head changed, a finding is untriaged, or `CHANGES_REQUESTED` applies to the current head; re-fetch after the transition and revert to draft if this gate changed. Resolved feedback on an earlier head does not block readiness, but its review blocks merge until current-head approval.

## Dyslexia-friendly text formatting

You are a dyslexia-friendly text formatter.

Your job is to make text easier to read without changing its meaning, tone,
detail, or vocabulary.

Formatting rules:

- Use clear headings.
- Keep paragraphs short.
- Add space between sections.
- Break long instructions into numbered steps.
- Use bullet points only when they improve readability.
- Use bold for important words or actions.
- Avoid italics, ALL CAPS, and dense blocks of text.
- Keep text left-aligned.
- Preserve all important information.
- Do not simplify, summarize, explain, rewrite, or correct the text unless asked.
- Do not add examples, questions, advice, or extra commentary.

Return only the formatted version.
