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

Compare both the composed global instructions and any replacement model prompt
from the repository root (diff exit code 1 means differences were found):

```powershell
. ./scripts/AgentCustomization.Common.ps1
$reviewedHashes = @{}
$reviewedModelHashes = @{}
foreach ($targetName in Get-CustomizationTargetNames -Target All) {
    $targetConfig = Get-CustomizationTarget -Name $targetName
    $liveRoot = Resolve-CustomizationHome -TargetName $targetName
    $liveFile = Join-Path $liveRoot $targetConfig.instructions.destination
    # Capture before reading the diff; do not refresh it after a concurrent edit.
    $reviewedHashes[$targetName] = Get-CustomizationInstructionHash -Path $liveFile
    if (Test-Path -LiteralPath $liveFile -PathType Leaf) {
        $compiledFile = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($compiledFile,
                (Get-CustomizationInstructionContent -Target $targetConfig))
            git diff --no-index -- $compiledFile $liveFile
            if ($LASTEXITCODE -gt 1) { throw "Cannot compare $targetName instructions." }
        } finally {
            Remove-Item -LiteralPath $compiledFile
        }
    } else {
        Write-Host "$targetName instructions are missing; no live content to compare."
    }
    if ($null -ne $targetConfig.PSObject.Properties['modelInstructions']) {
        $liveModel = Join-Path $liveRoot $targetConfig.modelInstructions.destination
        $reviewedModelHashes[$targetName] = Get-CustomizationInstructionHash -Path $liveModel
        if (Test-Path -LiteralPath $liveModel -PathType Leaf) {
            git diff --no-index -- $targetConfig.modelInstructions.source $liveModel
            if ($LASTEXITCODE -gt 1) { throw "Cannot compare $targetName model instructions." }
        } else {
            Write-Host "$targetName model instructions are missing; no live content to compare."
        }
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
./scripts/install.ps1 -ExpectedInstructionHashes $reviewedHashes `
    -ExpectedModelInstructionHashes $reviewedModelHashes
```

Install only one target:

```powershell
./scripts/install.ps1 -Target Codex `
    -ExpectedInstructionHashes @{ codex = $reviewedHashes.codex } `
    -ExpectedModelInstructionHashes @{ codex = $reviewedModelHashes.codex }
./scripts/install.ps1 -Target Claude `
    -ExpectedInstructionHashes @{ claude = $reviewedHashes.claude }
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

`status.ps1` reports `instructionHash` for the composed instruction file and
`modelInstructionHash` for the replacement model prompt. Each is `missing` when
its managed file is absent, or `null` with its corresponding `*HashError` when
the file cannot be hashed. For a target without a managed model prompt, both
model fields are `null` (not applicable). The summary counts the two error kinds
separately, and either causes a nonzero exit without erasing the drift report.

A hash proves file identity, not content review. `-ExpectedInstructionHashes`
must contain exactly the selected targets. A guarded install that selects a
managed model prompt also requires `-ExpectedModelInstructionHashes`, containing
exactly those selected targets with a model prompt (currently `codex`). Old
guarded Codex calls must add this second map; a global instruction hash alone
cannot protect the separate base prompt. A model-only guard is rejected. Pass
the maps from PowerShell, not as serialized strings to `pwsh -File`. Alternate
homes must be the same ones used for comparison.

The precondition checks both instruction files for all selected targets before
installation and checks each target again before creating its directories or
replacing files. A stale model hash therefore prevents changes to global
instructions, skills, hooks and other selected targets, including in `-WhatIf`.
On mismatch, reread and reconcile
the changed content rather than blindly replacing the expected hash. It detects
stale snapshots, including a previously missing file appearing, but is not an
atomic lock against a writer racing the final filesystem replacement. Coordinate
active writers before activation. The options add no deployment authority;
omitting both preserves the unguarded installer interface, not an exemption from
the content-review requirement above.

## Apply hook changes

Codex requires separate review and trust for new or changed personal hook
definitions. After a Codex deployment changes hooks, start Codex, open
`/hooks`, and trust each reviewed definition. Repository status proves source
and registration equality, but it cannot prove Codex's per-definition trust
state.

Claude Code applies changed hook definitions when a new session starts.
Sessions already running keep the hook snapshot captured at startup.

## Point Codex at the reviewed model instructions

The Codex target deploys `global/codex-model-instructions.md` to
`~/.codex/model-instructions.md`. It is the GPT-6 Sol base prompt from the
Codex model catalog with narrow changes where it conflicts with the effective
`AGENTS.md`, plus the closing format that was not reliable from `AGENTS.md`
alone. The same file is used when another model is selected, so compare
behavior on Sol, Astra, and Luna when the prompt or model changes.

Codex only loads it when `~/.codex/config.toml` names it. If an earlier
installation still points to `model-instructions-astra.md`, update that key
when separately authorizing deployment; the old file is not removed by this
repository. `config.toml` is not managed by this repository; add the key once,
at the top level, before any
`[table]` section:

```toml
model_instructions_file = "C:/Users/<you>/.codex/model-instructions.md"
```

Status reports the file as `ModelInstructions`; it does not verify the
`config.toml` key. The evaluation clients ignore user configuration, so both
evaluation scripts pass the manifest's reviewed file explicitly by default; the
shared rules are written against that configuration. Pass another file with
`-CodexModelInstructionsFile`, or `-StockCodexInstructions` to measure the stock
prompt:

```powershell
pwsh ./scripts/evaluate-instructions.ps1 -Target codex -CodexModel gpt-6-sol -CodexReasoningEffort medium
pwsh ./scripts/evaluate-instruction-actions.ps1 -Target codex -CodexModel gpt-6-astra -CodexReasoningEffort medium -StockCodexInstructions
```

## Scope boundary

For each selected target, the manifest owns:

- the ordered sources composing the target's global instruction file;
- the optional replacement model-instructions file for that target;
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
