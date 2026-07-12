# Agent customizations

Version-controlled global guidance and reusable custom skills for Codex and
Claude Code on Windows. This repository is the reviewed source of truth; the
tools' live configuration directories are deployment targets.

## Contents

- `AGENTS.md` with the root `CLAUDE.md` import — repository development and
  full-delivery policy shared by Codex and Claude Code.
- `global/AGENTS.md` — personal guidance applied across Codex repositories.
- `global/CLAUDE.md` — personal guidance applied across Claude Code projects.
- `skills/claude-runner` — resume-safe Codex wrapper for Claude Code CLI.
- `skills/execute-campaign-work-item` — scoped execution and evidence-backed
  handoff for one controller-assigned campaign work item.
- `skills/managed-jobs` — durable supervision for long-running local processes,
  shared by Codex and Claude Code.
- `skills/orchestrate-work-campaigns` — Codex-specific, visible,
  coordinator-only control of multi-task delivery campaigns.
- `config/manifest.json` — the exact files managed for each supported agent.
- `docs/customization-ownership.md` — classification, admission, ownership,
  precedence, and authoring rules for proposed customizations.
- `docs/maintaining-customizations.md` — maintenance rules for agent
  instructions, skill entrypoints, references, and progressive-disclosure
  validation.
- `scripts/verify.ps1` — validates structure and scans managed sources for
  common publication hazards.
- `scripts/status.ps1` — reports drift between this repository and live agent
  installations.
- `scripts/install.ps1` — explicitly deploys reviewed sources to one or both
  live installations.
- `scripts/test.ps1` — exercises verification, sandbox installations, clean
  status, target isolation, and drift detection.

Claude Code loads personal instructions from `~/.claude/CLAUDE.md` and
personal skills from `~/.claude/skills`. Codex uses `~/.codex/AGENTS.md` and
`~/.codex/skills`. The manifest reuses portable sources where possible and
keeps tool-specific skills on their compatible target.

## Why deployment is explicit

Symlinks and junctions are not the default because switching branches or
editing a worktree could otherwise change global agent behavior immediately.
The install step creates a deliberate boundary between reviewing a change and
activating it.

## Requirements

- PowerShell 7
- Git for clean-branch deployment checks
- A local Codex and/or Claude Code installation

## Workflow

An explicit request to implement a repository change defaults to the complete
branch-to-PR delivery workflow in [`AGENTS.md`](AGENTS.md): validate, commit,
push, open a bot-authored draft PR, obtain opposite-agent cross-review, triage
findings, and mark the PR ready for owner review. Current-head owner approval
then triggers a guarded merge or auto-merge after required checks pass.
Deployment to live agent homes remains a separate, explicitly authorized
activation step.

Validate the repository:

```powershell
pwsh ./scripts/verify.ps1
```

Run the deployment smoke test:

```powershell
pwsh ./scripts/test.ps1
```

Compare both live installations:

```powershell
pwsh ./scripts/status.ps1
```

Compare only one target:

```powershell
pwsh ./scripts/status.ps1 -Target Claude
```

Preview a deployment to both targets:

```powershell
pwsh ./scripts/install.ps1 -WhatIf
```

Deploy one target from a clean `main` checkout:

```powershell
pwsh ./scripts/install.ps1 -Target Codex
pwsh ./scripts/install.ps1 -Target Claude
```

`CODEX_HOME` and `CLAUDE_CONFIG_DIR` select non-default live directories. For
one-off targeting, pass `-CodexHome` or `-ClaudeHome`. The installer creates
timestamped backups under each target's `customization-backups` directory when
it replaces existing files.

## Scope boundary

The repository does not manage settings, authentication, plugins, caches,
memories, sessions, logs, artifacts, or managed-job records. Those surfaces can
contain machine-specific paths, private data, or generated state. The hook
scripts used by `managed-jobs` are versioned with the skill, while machine-local
hook registration remains outside this baseline.

Before adding guidance, use the [customization ownership and skill-admission
policy](docs/customization-ownership.md) to decide whether it belongs in global
guidance, a portable skill, a repository-local contract, or private/local
material. In particular, generic skills may coordinate repeated workflows and
discover target policy, but must not carry repository merge rules or private and
machine-specific state.

## License

MIT
