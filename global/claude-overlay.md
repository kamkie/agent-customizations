# Claude-specific tools

Before committing in a Claude-managed worktree with detached HEAD, create a `claude/<short-task-slug>` branch. For `codex-companion.mjs task`, `--write` requests write access; use `--prompt-file` for multiline prompts. Run `glab` inside the repository it targets. When a session starts from only a link, file or image and a session-title tool is available, title it in the first turn from what the input shows, and retitle it once the task is clear.
