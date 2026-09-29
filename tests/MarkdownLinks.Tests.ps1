[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/AgentCustomization.Common.ps1')
$repositoryRoot = Get-CustomizationRepositoryRoot
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$sandbox = Join-Path $temporaryRoot ('markdown-links-test-' + [guid]::NewGuid().ToString('N'))
$assertions = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}

try {
    Write-Host 'Markdown links: testing link resolution and code examples'
    $document = Join-Path $sandbox 'nested/source.md'
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $document)
    foreach ($name in @('existing.md', 'reference notes.md', 'hash#name.md', 'amp&name.md')) {
        [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $document) $name), '# Fixture')
    }
    [IO.File]::WriteAllText((Join-Path $sandbox 'parent.md'), '# Parent')
    $content = @'
[valid](existing.md)
[parent](../parent.md)
[spaces](<reference notes.md>)
[encoded](reference%20notes.md)
[fragment](existing.md#not-a-real-heading)
[hash filename](hash%23name.md#section)
[HTML entity](amp&name.md)
[external](https://example.invalid/not-requested)
[protocol-relative](//example.invalid/not-requested)
[custom scheme](app://example)
[heading](#not-a-real-heading)
`[inline example](missing-inline.md)`
```markdown
[fenced example](missing-fenced.md)
```
~~~markdown
[tilde-fenced example](missing-tilde.md)
~~~
'@
    [IO.File]::WriteAllText($document, $content)
    Assert-True (@(Get-MissingMarkdownFileLink -Path $document).Count -eq 0) 'Valid links or code examples produced missing-file findings.'
    [IO.File]::AppendAllText($document, "`n[missing](missing.md#section)`n[missing reference][ref]`n`n[ref]: missing-reference.md`n")
    $missing = @(Get-MissingMarkdownFileLink -Path $document)
    Assert-True ($missing.Count -eq 2) 'Missing inline and reference-style links were not both detected.'
    Assert-True ($missing[0].Source -eq $document -and $missing[0].Target -eq 'missing.md') 'Missing-link finding did not identify its source and file target.'
    Assert-True ($missing[1].Target -eq 'missing-reference.md') 'Reference-style target was not resolved.'

    Write-Host 'Markdown links: testing verifier integration with shipped sources'
    $fixture = Join-Path $sandbox 'repository'
    $null = New-Item -ItemType Directory -Path $fixture, (Join-Path $fixture 'scripts'), (Join-Path $fixture '.github')
    foreach ($directory in @('config', 'global', 'skills', 'hooks', 'tests')) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot $directory) -Destination $fixture -Recurse
    }
    foreach ($file in @('AGENTS.md', 'CLAUDE.md', 'README.md', 'LICENSE', 'SECURITY.md', '.github/CODEOWNERS', 'scripts/verify.ps1', 'scripts/AgentCustomization.Common.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot $file) -Destination (Join-Path $fixture $file)
    }
    # An unshipped Markdown document must not widen the verifier's link scope.
    [IO.File]::WriteAllText((Join-Path $fixture 'global/unmanaged.md'), '[unmanaged](missing-unmanaged.md)')
    $verifier = Join-Path $fixture 'scripts/verify.ps1'
    $output = @(& pwsh -NoProfile -File $verifier 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ('Shipped sources failed verification: ' + ($output -join ' '))

    $manifest = Get-CustomizationManifest
    $codex = $manifest.targets.codex
    $sources = @($codex.instructions.sources[0], $codex.modelInstructions.source,
        ('skills/' + $codex.skills[0] + '/references/link-fixture.md'))
    foreach ($source in $sources) {
        Write-Host "Markdown links: injecting a missing link into $source"
        $path = Join-Path $fixture $source
        $original = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { '' }
        [IO.File]::WriteAllText($path, $original + "`n[missing fixture](missing-fixture.md)`n")
        $output = @(& pwsh -NoProfile -File $verifier 2>&1)
        Assert-True ($LASTEXITCODE -eq 1) "Verifier accepted a missing link in $source."
        Assert-True (($output -join ' ') -like "*Missing local Markdown link: $source -> missing-fixture.md*") "Verifier did not identify the source and target in $source."
        [IO.File]::WriteAllText($path, $original)
    }
    Write-Host "Markdown file-link tests: $assertions assertions passed"
} finally {
    if (Test-Path -LiteralPath $sandbox) {
        $resolved = (Resolve-Path -LiteralPath $sandbox).Path
        if (-not $resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Unexpected test cleanup target: $resolved" }
        Remove-Item -LiteralPath $resolved -Recurse
    }
}
