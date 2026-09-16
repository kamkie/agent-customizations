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

Before activation, review the content differences in each drifted instruction
file, not only the drift count. Account for live-only guidance in the reviewed
sources or obtain explicit authority to discard it before replacing that file.
A backup preserves recovery data; it does not make an unreviewed loss acceptable.

For existing live instruction files, compare against their composed sources from
the repository root (diff exit code 1 means differences were found):

```powershell
. ./scripts/AgentCustomization.Common.ps1
$reviewedHashes = @{}
foreach ($targetName in Get-CustomizationTargetNames -Target All) {
    $targetConfig = Get-CustomizationTarget -Name $targetName
    $liveRoot = Resolve-CustomizationHome -TargetName $targetName
    $liveFile = Join-Path $liveRoot $targetConfig.instructions.destination
    # Capture before reading the diff; do not refresh it after a concurrent edit.
    $reviewedHashes[$targetName] = Get-CustomizationInstructionHash -Path $liveFile
    if (-not (Test-Path -LiteralPath $liveFile -PathType Leaf)) {
        Write-Host "$targetName instructions are missing; no live content to compare."
        continue
    }
    $compiledFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($compiledFile,
            (Get-CustomizationInstructionContent -Target $targetConfig))
        git diff --no-index -- $compiledFile $liveFile
        if ($LASTEXITCODE -gt 1) { throw "Cannot compare $targetName instructions." }
    } finally {
        Remove-Item -LiteralPath $compiledFile
    }
}
```

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

Install both targets, keeping the hashes from the content comparison above:

```powershell
./scripts/install.ps1 -ExpectedInstructionHashes $reviewedHashes
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

Only drifted managed files are replaced. The installer composes each target's
ordered shared and overlay instruction sources into its destination file.
Existing files are backed up under a timestamped `customization-backups`
directory in the selected target home, and the installer checks for remaining
drift before it succeeds.

`status.ps1` includes each target's current `instructionHash` (`missing` when
absent). A hash is evidence of file identity, not evidence that its content has
been reviewed. `-ExpectedInstructionHashes` accepts a hashtable containing exactly
the selected targets; for a single target use, for example,
`@{ codex = $reviewedHashes.codex }`. Pass it from PowerShell, not as a serialized
string to `pwsh -File`. Alternate homes must be the same ones used for comparison.

The precondition checks all targets before installation and checks a changed
instruction file again before replacement. On mismatch, reread and reconcile
the changed content rather than blindly replacing the expected hash. It detects
stale snapshots, including a previously missing file appearing, but is not an
atomic lock against a writer racing the final filesystem replacement. Coordinate
active writers before activation. The option adds no deployment authority;
omitting it preserves the existing installer interface, not an exemption from
the content-review requirement above.

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

- the ordered sources composing the target's global instruction file;
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
