[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/AgentCustomization.Common.ps1')
$assertions = 0
function Assert-Composition($condition, [string]$message) {
    if (-not $condition) { throw $message }
    $script:assertions++
}

$manifest = Get-CustomizationManifest
$shared = Get-CustomizationInstructionContent -Sources @('global/shared.md')
foreach ($targetName in @('codex', 'claude')) {
    $target = $manifest.targets.$targetName
    $parts = foreach ($kind in @('instructions', 'modelInstructions')) {
        if ($target.PSObject.Properties[$kind]) {
            Get-CustomizationInstructionContent -Target $target -Kind $kind
        }
    }
    $loaded = $parts -join "`n"
    $policy = $shared.TrimEnd()
    Assert-Composition ($loaded.IndexOf($policy, [StringComparison]::Ordinal) -ge 0) "$targetName has no complete shared policy."
    Assert-Composition ($loaded.IndexOf($policy, [StringComparison]::Ordinal) -eq $loaded.LastIndexOf($policy, [StringComparison]::Ordinal)) "$targetName loads multiple copies of shared policy."
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('instruction-composition-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'first.md'), "First policy: café.`r`n`r`n")
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'second.md'), "Second policy.`n")
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'empty.md'), "`n")
    # Isolate composition inputs without editing any real policy source.
    function Get-CustomizationRepositoryRoot { return $fixtureRoot }
    $target = [pscustomobject]@{
        instructions = [pscustomobject]@{ sources = @('first.md') }
        modelInstructions = [pscustomobject]@{ sources = @('second.md', 'first.md') }
    }
    Assert-Composition ((Get-CustomizationInstructionContent -Target $target) -ceq "First policy: café.`n") 'Single source composition failed.'
    Assert-Composition ((Get-CustomizationInstructionContent -Target $target -Kind modelInstructions) -ceq "Second policy.`n`nFirst policy: café.`n") 'Model source order or newline normalization changed.'
    Assert-Composition ((Get-CustomizationInstructionContent -Sources @('first.md', 'second.md')) -ceq "First policy: café.`n`nSecond policy.`n") 'Explicit source composition failed.'
    foreach ($source in @('empty.md', 'missing.md')) {
        $rejected = $false
        try { Get-CustomizationInstructionContent -Sources @($source) | Out-Null } catch { $rejected = $true }
        Assert-Composition $rejected "Invalid source $source was accepted."
    }
    $rejected = $false
    try { Get-CustomizationInstructionContent -Target ([pscustomobject]@{ instructions = [pscustomobject]@{} }) | Out-Null } catch { $rejected = $true }
    Assert-Composition $rejected 'Missing source list was accepted.'
    Write-Host "Instruction composition tests: OK ($assertions assertions)"
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $temporaryPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse }
}
