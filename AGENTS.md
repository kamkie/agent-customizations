# Codex customizations repository

This repository is the reviewed source of truth for the global Codex guidance
and custom skills listed in `config/manifest.json`. The live files under
`$CODEX_HOME` or `~/.codex` are deployment targets, not editing locations.

## Working rules

- Keep global guidance in `global/AGENTS.md` and each skill inside its own
  `skills/<name>/` directory.
- Do not import sessions, memories, logs, artifacts, managed-job records,
  credentials, plugin caches, or machine-generated configuration.
- Keep examples portable. Do not commit usernames, home-directory paths,
  repository-specific absolute paths, tokens, or session identifiers.
- Treat changes to different skills as separate commits when practical.
- Run `pwsh ./scripts/verify.ps1` before committing.
- Run `pwsh ./scripts/test.ps1` after changing deployment tooling.
- Use `pwsh ./scripts/status.ps1` to compare reviewed source with the live Codex
  installation.
- Do not run `install.ps1` unless deployment to the live Codex installation is
  explicitly authorized. Installation is an activation step, not validation.
- Develop changes on a branch or worktree. Deploy from a clean `main` checkout
  unless the user explicitly authorizes another source.

Machine-specific hook registration remains outside this repository unless a
portable, reviewable installation mechanism is added deliberately.
