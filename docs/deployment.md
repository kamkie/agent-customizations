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
    foreach ($kind in @('instructions', 'modelInstructions')) {
        $surface = $targetConfig.PSObject.Properties[$kind]
        if (-not $surface) { continue }
        $liveFile = Join-Path $liveRoot $surface.Value.destination
        # Capture before the diff; do not refresh after a concurrent edit.
        $snapshot = Get-CustomizationInstructionHash -Path $liveFile
        if ($kind -eq 'instructions') { $reviewedHashes[$targetName] = $snapshot }
        else { $reviewedModelHashes[$targetName] = $snapshot }
        if ($snapshot -eq 'missing') {
            Write-Host "$targetName $kind are missing; no live content to compare."
            continue
        }
        $compiledFile = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($compiledFile,
                (Get-CustomizationInstructionContent -Target $targetConfig -Kind $kind))
            git diff --no-index -- $compiledFile $liveFile
            if ($LASTEXITCODE -gt 1) { throw "Cannot compare $targetName $kind." }
        } finally {
            Remove-Item -LiteralPath $compiledFile
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

Only drifted managed files are replaced. The installer composes each instruction surface's ordered sources into its
destination file; it uses the same composition for installation and drift checks.
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

The Codex target composes `global/shared.md` followed by
`global/codex-model-instructions.md` into `~/.codex/model-instructions-astra.md`.
The shared execution contract appears only in that base; Codex's `AGENTS.md`
contains only `global/codex-overlay.md`. Claude's `CLAUDE.md` composes
`global/shared.md` and `global/claude-overlay.md` instead. Both agents therefore
receive one copy of the common policy from one reviewed source.

The manifest's schema 5 uses ordered `sources` for both instruction surfaces;
the old single model `source` is replaced, not retained as a second path.
The model file replaces the built-in base. Its Codex-specific fragment owns
runtime/tool/rendering behavior, while shared policy has one owner. Review
changes to the stock base when updating Codex, without copying its conflicting
permission and completion defaults back over the shared contract.

Codex only loads it when `~/.codex/config.toml` names it. `config.toml` is not
managed by this repository; add the key once, at the top level, before any
`[table]` section:

```toml
model_instructions_file = "C:/Users/<you>/.codex/model-instructions-astra.md"
```

Status reports the file as `ModelInstructions`; it does not verify the
`config.toml` key. The evaluation clients ignore user configuration, so both
evaluation scripts compose the manifest's reviewed base into their run output
and pass that snapshot explicitly. That artifact is the complete base, not the
Codex runtime fragment alone. Pass a complete replacement with
`-CodexModelInstructionsFile`, or `-StockCodexInstructions` for a stock-base
comparison. The stock comparison loads the same shared personal policy through
AGENTS.md, so it measures that different instruction placement without silently
omitting the policy:

```powershell
pwsh ./scripts/evaluate-instructions.ps1 -Target codex
pwsh ./scripts/evaluate-instruction-actions.ps1 -Target codex -StockCodexInstructions
```

`--ignore-user-config` does not suppress Codex's home-level AGENTS.md. Before
claiming an isolated candidate result, inspect the native session's loaded
instruction sources. Record any live global contribution and its hash; a
pre-install run with old global guidance is a mixed-layer check, not proof of the
final deployed composition. Do not edit live instructions or copy credentials
to isolate a test. After authorized activation, verify the fresh Desktop/CLI
session loads the generated base and small global overlay. Controlled action
checks prove their observed tool effects; they are not a general reliability
guarantee.

## Select the reviewed OpenAI Docs skill

The manifest installs this repository's `skills/openai-docs` as a personal skill.
It does not edit the bundled `.system` skill. Codex does not merge same-name
skills, so installation alone does not replace the bundled route. During an
explicitly authorized activation, inspect the discovered paths and add or update
only the bundled skill's entry in the user's existing `config.toml`:

```toml
[[skills.config]]
path = "C:/Users/<you>/.codex/skills/.system/openai-docs/SKILL.md"
enabled = false
```

Use the actual absolute bundled path reported by that installation. Preserve
other settings and do not create duplicate entries. Leave the reviewed personal
`skills/openai-docs/SKILL.md` enabled. Restart Codex and verify that its skill
catalog selects the personal copy for this workflow. This is the documented
[skill disable mechanism](https://learn.chatgpt.com/docs/build-skills#enable-or-disable-local-codex-skills);
`config.toml` remains outside the installer's managed files, as with the model
prompt selection. Without this activation step, both names may appear and the
new route is not proven active. Never delete or patch the bundled cache to force
selection. No configuration change is part of repository validation.

## Scope boundary

For each selected target, the manifest owns:

- the ordered sources composing the target's global instruction file;
- the ordered sources composing its optional replacement model-instructions file;
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
