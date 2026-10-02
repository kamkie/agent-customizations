# Claude-specific tools

Before committing in a Claude-managed worktree with detached HEAD, create a `claude/<short-task-slug>` branch. For `codex-companion.mjs task`, `--write` requests write access; use `--prompt-file` for multiline prompts. Run `glab` inside the repository it targets. When a session starts from only a link, file or image and a session-title tool is available, title it in the first turn from what the input shows, and retitle it once the task is clear.

To monitor pull-request CI, start `gh pr checks <number> --repo <owner>/<repo> --watch --required` (or the host CLI's equivalent) as a `managed-jobs` job with `-Lifetime Session`, then block on it with repeated `wait -Id <job-id> -TimeoutSeconds 540` calls until it ends, and read its exit code and log. If it reports no checks yet, start it again once the pipeline registers. The user wants this wait done by you, which overrides any app default against polling CI yourself; enabling an app CI monitor does not replace it.
