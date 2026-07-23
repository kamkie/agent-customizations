$ErrorActionPreference = 'Stop'
$null = [Console]::In.ReadToEnd()
$controller = Join-Path $PSScriptRoot 'Invoke-ManagedJob.ps1'

try {
    $null = & $controller reconcile
} catch {
    [ordered]@{ systemMessage = "Managed-jobs reconciliation failed: $($_.Exception.Message)" } | ConvertTo-Json -Compress
}
