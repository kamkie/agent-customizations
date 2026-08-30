[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Controller,
    [Parameter(Mandatory)][ValidateSet('reconcile', 'prune')][string]$Action,
    [Parameter(Mandatory)][string]$StateRoot,
    [string]$StatusCsv,
    [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Controller -PathType Leaf)) {
    throw "Managed-jobs controller not found: $Controller"
}
if ($Action -eq 'prune' -and [string]::IsNullOrWhiteSpace($PlanPath)) {
    throw 'Async prune requires a frozen maintenance plan.'
}
if ($Action -ne 'prune' -and $PlanPath) {
    throw '-PlanPath is valid only for prune maintenance.'
}

$controllerParameters = @{ StateRoot = $StateRoot }
if ($StatusCsv) {
    $controllerParameters.Status = @($StatusCsv.Split(',', [StringSplitOptions]::RemoveEmptyEntries))
}
if ($PlanPath) {
    $controllerParameters.MaintenancePlan = $PlanPath
}

try {
    while ($true) {
        try {
            & $Controller $Action @controllerParameters
            break
        } catch {
            if ($_.Exception.GetBaseException().Message -cne
                'Another managed-jobs maintenance operation is already running.') {
                throw
            }
            Start-Sleep -Milliseconds 250
        }
    }
} finally {
    if ($PlanPath -and (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
        Remove-Item -LiteralPath $PlanPath -Force -ErrorAction SilentlyContinue
    }
}
