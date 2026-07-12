[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$sandbox = Join-Path $temporaryRoot ('agent-customizations-test-' + [guid]::NewGuid().ToString('N'))
$resolvedSandbox = [IO.Path]::GetFullPath($sandbox)
if (-not $resolvedSandbox.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use a test path outside the system temporary directory: $resolvedSandbox"
}
$codexSandbox = Join-Path $resolvedSandbox 'codex'
$claudeSandbox = Join-Path $resolvedSandbox 'claude'

try {
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'verify.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Repository verification test failed.' }

    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'install.ps1') `
        -Target All `
        -CodexHome $codexSandbox `
        -ClaudeHome $claudeSandbox `
        -AllowDirty `
        -AllowNonMain
    if ($LASTEXITCODE -ne 0) { throw 'Sandbox installation test failed.' }

    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'status.ps1') `
        -Target All `
        -CodexHome $codexSandbox `
        -ClaudeHome $claudeSandbox `
        -SummaryOnly
    if ($LASTEXITCODE -ne 0) { throw 'Installed sandboxes should be in sync.' }

    Add-Content -LiteralPath (Join-Path $claudeSandbox 'CLAUDE.md') -Value "`n# deliberate test drift"
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'status.ps1') `
        -Target Claude `
        -ClaudeHome $claudeSandbox `
        -SummaryOnly
    if ($LASTEXITCODE -ne 1) { throw 'Claude status should return exit code 1 after deliberate drift.' }

    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'status.ps1') `
        -Target Codex `
        -CodexHome $codexSandbox `
        -SummaryOnly
    if ($LASTEXITCODE -ne 0) { throw 'Claude drift should not affect Codex status.' }

    Write-Host 'Deployment smoke test: OK'
} finally {
    if (Test-Path -LiteralPath $resolvedSandbox) {
        $confirmed = [IO.Path]::GetFullPath($resolvedSandbox)
        if (-not $confirmed.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a path outside the system temporary directory: $confirmed"
        }
        Remove-Item -LiteralPath $confirmed -Recurse -Force
    }
}

exit 0
