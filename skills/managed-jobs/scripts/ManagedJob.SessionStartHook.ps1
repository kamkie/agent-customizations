$ErrorActionPreference = 'Stop'
$null = [Console]::In.ReadToEnd()
$controller = Join-Path $PSScriptRoot 'Invoke-ManagedJob.ps1'

try {
    $summary = (& $controller reconcile | Out-String) | ConvertFrom-Json
    $parts = @()
    if ($summary.running -or $summary.starting) {
        $active = @($summary.active | ForEach-Object { "$($_.id) [$($_.status)] $($_.name); log=$($_.logPath)" })
        $parts += "Managed jobs active after reconciliation: $($active -join ' | '). Reuse or inspect them before starting equivalents."
    }
    if ($summary.orphaned) {
        $parts += "$($summary.orphaned) managed job record(s) are orphaned; inspect them with the managed-jobs skill."
    }
    if ($parts.Count) {
        [ordered]@{
            hookSpecificOutput = [ordered]@{
                hookEventName = 'SessionStart'
                additionalContext = $parts -join ' '
            }
        } | ConvertTo-Json -Depth 6 -Compress
    }
} catch {
    [ordered]@{ systemMessage = "Managed-jobs reconciliation failed: $($_.Exception.Message)" } | ConvertTo-Json -Compress
}
