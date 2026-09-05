[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$skillDirectory = Split-Path -Parent $PSScriptRoot
$repositoryRoot = (Resolve-Path (Join-Path $skillDirectory '..\..')).Path
$temporaryDirectory = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $temporaryDirectory ('managed-jobs-profile-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot

try {
    $probePath = Join-Path $testRoot 'probe.ps1'
    @'
param([string]$SkillDirectory, [string]$RepositoryRoot, [string]$TestRoot, [switch]$MissingProfile)
$ErrorActionPreference = 'Stop'
if ($MissingProfile -and -not [string]::IsNullOrEmpty($HOME)) {
    throw 'The child shell did not reproduce the missing profile environment.'
}
. (Join-Path $SkillDirectory 'scripts\ManagedJob.Common.ps1')
$expectedRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.agent-customizations\managed-jobs'
if ((Get-ManagedJobAutomaticCleanupRoot) -ne $expectedRoot) {
    throw 'Default registry did not resolve to the Windows user profile.'
}
$env:MANAGED_JOBS_ROOT = Join-Path $TestRoot 'state'
if ((Get-ManagedJobAutomaticCleanupRoot) -ne $env:MANAGED_JOBS_ROOT) {
    throw 'The explicit registry override was not preserved.'
}
$controller = Join-Path $SkillDirectory 'scripts\Invoke-ManagedJob.ps1'
$summary = (& $controller cleanup -OwnerAgent codex -OwnerSessionId profile-test -CleanupLifetime Turn | Out-String) | ConvertFrom-Json
if ($summary.matched -ne 0 -or @($summary.failures).Count -ne 0) {
    throw 'Cleanup of the isolated empty registry failed.'
}
# The source checkout has the same skills layout as an installed agent home.
$env:CODEX_HOME = $RepositoryRoot
$env:CODEX_THREAD_ID = 'profile-test'
$hook = Join-Path $RepositoryRoot 'hooks\codex\managed-jobs\ManagedJob.StopHook.ps1'
$output = & $hook | Out-String
if ($LASTEXITCODE -ne 0 -or -not [string]::IsNullOrWhiteSpace($output)) {
    throw "The actual Stop hook did not finish cleanly: $output"
}
'@ | Set-Content -LiteralPath $probePath -Encoding utf8

    foreach ($missingProfile in @($false, $true)) {
        $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($name in @('CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'MANAGED_JOBS_ROOT')) {
            $null = $startInfo.Environment.Remove($name)
        }
        if ($missingProfile) {
            foreach ($name in @('HOME', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH')) {
                $null = $startInfo.Environment.Remove($name)
            }
        } else {
            $startInfo.Environment['USERPROFILE'] = [Environment]::GetFolderPath('UserProfile')
        }
        foreach ($argument in @('-NoProfile', '-File', $probePath, '-SkillDirectory', $skillDirectory,
                '-RepositoryRoot', $repositoryRoot, '-TestRoot', $testRoot)) {
            $startInfo.ArgumentList.Add($argument)
        }
        if ($missingProfile) { $startInfo.ArgumentList.Add('-MissingProfile') }
        $process = [Diagnostics.Process]::Start($startInfo)
        try {
            $process.StandardInput.Close()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(15000)) {
                $process.Kill($true)
                throw 'Profile regression probe timed out.'
            }
            if ($process.ExitCode -ne 0) {
                throw "Profile probe failed (missing profile: $missingProfile): $($stderr.Result) $($stdout.Result)"
            }
        } finally { $process.Dispose() }
    }
    Write-Host 'PASS: default profile, remote profile, registry override, cleanup, and Stop hook.'
} finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedTestRoot.StartsWith([IO.Path]::TrimEndingDirectorySeparator($temporaryDirectory) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing cleanup outside the temporary directory.'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
