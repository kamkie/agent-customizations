[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$sandbox = Join-Path $temporaryRoot ('codex-customizations-test-' + [guid]::NewGuid().ToString('N'))
$resolvedSandbox = [IO.Path]::GetFullPath($sandbox)
if (-not $resolvedSandbox.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use a test path outside the system temporary directory: $resolvedSandbox"
}

try {
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'verify.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Repository verification test failed.' }

    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'install.ps1') `
        -CodexHome $resolvedSandbox `
        -AllowDirty `
        -AllowNonMain
    if ($LASTEXITCODE -ne 0) { throw 'Sandbox installation test failed.' }

    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'status.ps1') `
        -CodexHome $resolvedSandbox `
        -SummaryOnly
    if ($LASTEXITCODE -ne 0) { throw 'Installed sandbox should be in sync.' }

    Add-Content -LiteralPath (Join-Path $resolvedSandbox 'AGENTS.md') -Value "`n# deliberate test drift"
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'status.ps1') `
        -CodexHome $resolvedSandbox `
        -SummaryOnly
    if ($LASTEXITCODE -ne 1) { throw 'Status should return exit code 1 after deliberate drift.' }

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
