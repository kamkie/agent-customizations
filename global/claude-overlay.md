## Claude-specific tools

Before committing in a Claude-managed worktree, check whether `HEAD` is
detached. If it is, create a local `claude/<short-task-slug>` branch before or
immediately after the commit unless the user asked not to create a branch.

For `codex-companion.mjs task`, read-only is the default and `--write` requests
write access; there is no `--read-only` flag. Unknown flags leak into the prompt.
Use `--prompt-file <path>` for multi-line or formatted prompts because a quoted
prompt argument loses quotes, backslashes, and newlines.

Run `glab` inside the repository it targets. Running it elsewhere with `--repo`
can add a `glab-base` remote to the current repository; remove that stray remote
with `git remote remove glab-base` if it occurs.
