# Deployment

This guide owns validation, live-drift inspection, and activation of the
reviewed sources declared in [`config/manifest.json`](../config/manifest.json)
for Codex and Claude Code.

## Authorization boundary

Deployment writes to live agent configuration directories and requires a
separate, explicit instruction to activate reviewed changes. Authorization to
edit, validate, commit, push, or open a pull request does not authorize
`scripts/install.ps1`.

Edit the reviewed sources in this repository, not their installed copies.
Verification, tests, and status inspection do not deploy changes.

## Requirements

- PowerShell 7
- Git for clean-branch deployment checks
- A local Codex and/or Claude Code installation

## Validate the reviewed source

Run structural and publication-safety verification:

```powershell
pwsh ./scripts/verify.ps1
```

Run the deployment smoke test:

```powershell
pwsh ./scripts/test.ps1
```

The smoke test installs into temporary sandboxes. It does not write to the live
Codex or Claude Code configuration directories.

## Inspect live drift

Compare both live installations with the reviewed source:

```powershell
pwsh ./scripts/status.ps1
```

Inspect one target:

```powershell
pwsh ./scripts/status.ps1 -Target Codex
pwsh ./scripts/status.ps1 -Target Claude
```

`CODEX_HOME` and `CLAUDE_CONFIG_DIR` select non-default live directories.
For one-off inspection, pass `-CodexHome <path>` or `-ClaudeHome <path>`.

The status command reports managed files as in sync, missing, different, or
extra. It exits with status 1 when it detects drift. Drift is evidence to
review; it is not permission to install.

## Preview activation

Preview all target changes without writing to either live installation:

```powershell
pwsh ./scripts/install.ps1 -WhatIf
```

Preview one target or an alternate home:

```powershell
pwsh ./scripts/install.ps1 -Target Codex -WhatIf
pwsh ./scripts/install.ps1 -Target Claude -ClaudeHome <path> -WhatIf
```

The installer runs repository verification and its clean-`main` safeguards
before producing a preview. `-WhatIf` does not bypass those safeguards, so run
previews from a clean, current `main` checkout.

## Activate reviewed changes

Activation requires its own explicit authorization. Deploy from a clean,
current `main` checkout:

```powershell
git switch main
git pull --ff-only
git status --short --branch
```

Install both targets:

```powershell
pwsh ./scripts/install.ps1
```

Install only one target:

```powershell
pwsh ./scripts/install.ps1 -Target Codex
pwsh ./scripts/install.ps1 -Target Claude
```

The installer verifies the repository before writing and refuses dirty,
detached, or non-`main` checkouts by default. `-AllowDirty` and
`-AllowNonMain` are explicit safeguards for exceptional use; they do not grant
deployment authorization.

Only drifted managed files are replaced. Existing files are backed up under a
timestamped `customization-backups` directory in the selected target home, and
the installer checks for remaining drift before it succeeds.

## Apply hook changes

Codex requires separate review and trust for new or changed personal hook
definitions. After a Codex deployment changes hooks, start Codex, open
`/hooks`, and trust each reviewed definition. Repository status proves source
and registration equality, but it cannot prove Codex's per-definition trust
state.

Claude Code applies changed hook definitions when a new session starts.
Sessions already running keep the hook snapshot captured at startup.

## Scope boundary

For each selected target, the manifest owns:

- the target's global instruction file;
- the compatible skills listed for that target;
- the reviewed hook scripts; and
- the reviewed hook registrations in `hooks.json` for Codex or `settings.json`
  for Claude Code.

The installer preserves unrelated hook entries and Claude Code settings when it
merges reviewed registrations. The merge preserves those entries semantically
but may reformat the machine-local JSON file.

The repository does not manage unrelated settings, authentication, plugins,
caches, memories, sessions, logs, artifacts, managed-job records, or other
machine-generated state. These surfaces can contain private or machine-specific
material and remain outside the reviewed source boundary.
