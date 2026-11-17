# Deployment

This guide owns validation, live-drift inspection, and activation of the reviewed sources declared in [`config/manifest.json`](../config/manifest.json) for Codex, Claude Code, and GitHub Copilot.

## Authorization boundary

Deployment writes to live agent configuration directories and requires a separate, explicit instruction to activate reviewed changes, or the owner's merge report as [`AGENTS.md`](../AGENTS.md#request-authority) defines it. Authorization to edit, validate, commit, push, or open a pull request does not authorize `scripts/install.ps1`.

Edit the reviewed sources in this repository, not their installed copies. Verification, tests, and status inspection do not deploy changes.

## Requirements

- PowerShell 7
- Git for clean-branch deployment checks
- A local Codex, Claude Code, and/or GitHub Copilot installation

## Validate the reviewed source

Run structural and publication-safety verification:

```powershell
pwsh ./scripts/verify.ps1
```

Run the deployment smoke test:

```powershell
pwsh ./scripts/test.ps1
```

The smoke test installs into temporary sandboxes. It does not write to the live Codex, Claude Code, or GitHub Copilot configuration directories.

## Inspect live drift

Compare live installations with the reviewed source:

```powershell
pwsh ./scripts/status.ps1
```

Inspect one target:

```powershell
pwsh ./scripts/status.ps1 -Target Codex
pwsh ./scripts/status.ps1 -Target Claude
pwsh ./scripts/status.ps1 -Target Copilot
```

`CODEX_HOME`, `CLAUDE_CONFIG_DIR`, and `COPILOT_HOME` select non-default live directories. For one-off inspection, pass `-CodexHome <path>`, `-ClaudeHome <path>`, or `-CopilotHome <path>`.

The status command reports managed files as in sync, missing, different, or extra. It exits with status 1 when it detects drift. Drift is evidence to review; it is not permission to install.

Before activation, review the content differences in each drifted instruction file, not only the drift count. Account for live-only guidance in the reviewed sources or obtain explicit authority to discard it before replacing that file. A backup preserves recovery data; it does not make an unreviewed loss acceptable.

Compare the composed global instructions from the repository root (diff exit code 1 means differences were found):

```powershell
. ./scripts/AgentCustomization.Common.ps1
$reviewedHashes = @{}
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
}
```

## Preview activation

Preview all target changes without writing to any live installation:

```powershell
pwsh ./scripts/install.ps1 -WhatIf
```

Preview one target or an alternate home:

```powershell
pwsh ./scripts/install.ps1 -Target Codex -WhatIf
pwsh ./scripts/install.ps1 -Target Claude -ClaudeHome <path> -WhatIf
pwsh ./scripts/install.ps1 -Target Copilot -CopilotHome <path> -WhatIf
```

The installer runs repository verification and its clean-`main` safeguards before producing a preview. `-WhatIf` does not bypass those safeguards, so run previews from a clean, current `main` checkout.

## Activate reviewed changes

Activation requires authorization under the [boundary above](#authorization-boundary). Deploy from a clean, current `main` checkout:

```powershell
git switch main
git pull --ff-only
git status --short --branch
```

Install all targets, keeping the hashes from the content comparison above:

```powershell
./scripts/install.ps1 -ExpectedInstructionHashes $reviewedHashes
```

Install only one target:

```powershell
./scripts/install.ps1 -Target Codex `
    -ExpectedInstructionHashes @{ codex = $reviewedHashes.codex }
./scripts/install.ps1 -Target Claude `
    -ExpectedInstructionHashes @{ claude = $reviewedHashes.claude }
./scripts/install.ps1 -Target Copilot `
    -ExpectedInstructionHashes @{ copilot = $reviewedHashes.copilot }
```

The installer verifies the repository before writing and refuses dirty, detached, or non-`main` checkouts by default. `-AllowDirty` and `-AllowNonMain` are explicit safeguards for exceptional use; they do not grant deployment authorization.

Only drifted managed files are replaced. The installer composes each target's ordered shared and overlay instruction sources into its destination file. Existing files are backed up under a timestamped `customization-backups` directory in the selected target home, and the installer checks for remaining drift before it succeeds.

`status.ps1` reports `instructionHash` for each composed instruction file: `missing` when absent, or `null` with `instructionHashError` when hashing fails. A hash error causes a nonzero exit without erasing the drift report.

A hash proves file identity, not content review. Pass `-ExpectedInstructionHashes` as a PowerShell map with exactly the selected targets, using the same homes as the comparison. Remove the retired `-ExpectedModelInstructionHashes` argument from older deployment commands.

The installer checks all selected instruction files before writing any target, including during preview, and rechecks each target before replacing files. If a file changed or appeared after review, reread and reconcile it before refreshing its hash. This guard is not an atomic lock; coordinate active writers before activation.

## Apply hook changes

Codex requires separate review and trust for new or changed personal hook definitions. After a Codex deployment changes hooks, start Codex, open `/hooks`, and trust each reviewed definition. Repository status proves source and registration equality, but it cannot prove Codex's per-definition trust state.

Claude Code applies changed hook definitions when a new session starts. Sessions already running keep the hook snapshot captured at startup.

The closing-phrase Stop hook can make an agent rewrite its ending once per turn: it blocks the first stop when the last 500 characters of the final message dictate a reply phrase or offer a check instead of running it, and never blocks a stop that a hook already continued. Its whole pattern list is in `hooks/shared/closing-phrase/ClosingPhrase.StopHook.ps1`.

GitHub Copilot has no managed-jobs hook registrations in the manifest; its installed `managed-jobs` skill runs without automatic startup reconciliation or turn/session cleanup hooks, so Copilot sessions must explicitly stop started jobs and run `reconcile` after an interrupted session.

## Apply plugin changes

Claude Code loads each plugin installed under `~/.claude/skills/<name>` as `<name>@skills-dir` in new sessions; `claude plugin list` shows its state. A same-named plugin loaded through `CLAUDE_CODE_PLUGIN_DIRS` or `--plugin-dir` takes precedence, so remove that entry to load the reviewed copy. Status ignores the type declarations Claude Code generates under a plugin's `.claude-plugin/types/`.

## Switch to stock Codex prompts

New installs use the selected model's built-in instructions. Personal rules come from the shared instructions and Codex overlay in `~/.codex/AGENTS.md`.

For an installation that used the Sol 6.1 replacement, install the reviewed overlay during authorized deployment. Then remove the top-level `model_instructions_file` setting from `~/.codex/config.toml` **if it points to the retired `model-instructions-astra.md`**. Keep the model selection and all other settings. Start a fresh Codex session to use the selected model's stock prompt. A different custom pointer is outside this migration.

The installer and status command do not manage or inspect the local pointer; a clean status alone does not establish that the switch is active. The old file can stay on disk unreferenced.

Both evaluators ignore the user's `config.toml` and use stock instructions by default. To compare a different prompt, pass `-CodexModelInstructionsFile <path>`; `-StockCodexInstructions` explicitly selects the default.

```powershell
pwsh ./scripts/evaluate-instructions.ps1 -Target codex -CodexModel gpt-6.2-sol
pwsh ./scripts/evaluate-instruction-actions.ps1 -Target codex -CodexModel gpt-6.2-astra
```

## Scope boundary

For each selected target, the manifest owns:

- the ordered sources composing the target's global instruction file;
- the compatible skills listed for that target;
- the target's plugins from `plugins/<target>/<name>`, copied into the manifest's plugin destination;
- the reviewed hook scripts; and
- the reviewed hook registrations in `hooks.json` for Codex or `settings.json` for Claude Code.

The installer preserves unrelated hook entries and Claude Code settings when it merges reviewed registrations. The merge preserves those entries semantically but may reformat the machine-local JSON file.

The repository does not manage unrelated settings, authentication, other plugins, marketplaces, plugin caches, memories, sessions, logs, artifacts, managed-job records, or other machine-generated state. These surfaces can contain private or machine-specific material and remain outside the reviewed source boundary.
