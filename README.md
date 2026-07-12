# Codex customizations

Version-controlled global guidance and reusable custom skills for Codex on
Windows. This repository is the reviewed source of truth; `~/.codex` is the
live runtime installation.

## Contents

- `global/AGENTS.md` — personal guidance applied across repositories.
- `skills/claude-runner` — resume-safe foreground wrapper for Claude Code CLI.
- `skills/managed-jobs` — durable supervision for long-running local processes.
- `skills/orchestrate-work-campaigns` — visible, evidence-backed coordination of
  multi-task delivery campaigns.
- `config/manifest.json` — the exact set of files managed by this repository.
- `scripts/verify.ps1` — validates structure and scans managed sources for
  common publication hazards.
- `scripts/status.ps1` — reports drift between this repository and the live
  Codex installation.
- `scripts/install.ps1` — explicitly deploys reviewed sources to the live
  installation.
- `scripts/test.ps1` — exercises verification, sandbox installation, clean
  status, and drift detection.

## Why deployment is explicit

The repository normally lives in a regular checkout such as
`D:\Projects\github.com\<owner>\codex-customizations`. Codex continues to read
its live files from `$CODEX_HOME` or `~/.codex`.

Symlinks and junctions are not the default because switching branches or
editing a worktree could otherwise change global Codex behavior immediately.
The install step creates a deliberate boundary between reviewing a change and
activating it.

## Requirements

- PowerShell 7
- Git for clean-branch deployment checks
- A local Codex installation

## Workflow

Validate the repository:

```powershell
pwsh ./scripts/verify.ps1
```

Run the deployment smoke test:

```powershell
pwsh ./scripts/test.ps1
```

Compare it with the live installation:

```powershell
pwsh ./scripts/status.ps1
```

Preview a deployment:

```powershell
pwsh ./scripts/install.ps1 -WhatIf
```

Deploy from a clean `main` checkout:

```powershell
pwsh ./scripts/install.ps1
```

Set `CODEX_HOME` or pass `-CodexHome` to target a non-default installation.
The installer creates timestamped backups under
`$CODEX_HOME/customization-backups` when it replaces existing files.

## Scope boundary

The repository does not manage `hooks.json`, `config.toml`, authentication,
plugins, caches, memories, sessions, logs, artifacts, or managed-job records.
Those surfaces can contain machine-specific paths, private data, or generated
state. The hook scripts used by `managed-jobs` are versioned with the skill,
while machine-local hook registration remains outside this baseline.

## License

MIT
