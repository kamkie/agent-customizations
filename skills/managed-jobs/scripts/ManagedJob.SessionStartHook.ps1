$ErrorActionPreference = 'Stop'
$null = [Console]::In.ReadToEnd()
$controller = Join-Path $PSScriptRoot 'Invoke-ManagedJob.ps1'
. (Join-Path $PSScriptRoot 'ManagedJob.Common.ps1')

function Test-SameManagedJobSet {
    param($Left, $Right)
    return ((@($Left) -join "`0") -ceq (@($Right) -join "`0"))
}

try {
    $summary = (& $controller reconcile | Out-String) | ConvertFrom-Json
    $noticeStatePath = Join-Path ([string]$summary.stateRoot) 'session-start-notice.json'
    $previousState = $null
    if (Test-Path -LiteralPath $noticeStatePath -PathType Leaf) {
        try {
            $previousState = Get-Content -LiteralPath $noticeStatePath -Raw | ConvertFrom-Json
            $previousProperties = @($previousState.PSObject.Properties.Name)
            if ($previousProperties -notcontains 'active' -or $previousProperties -notcontains 'orphaned') {
                $previousState = $null
            }
        } catch {
            $previousState = $null
        }
    }

    $activeSet = @($summary.active | Sort-Object id | ForEach-Object { "$($_.id)|$($_.status)" })
    $orphanedSet = @($summary.jobs | Where-Object status -eq 'orphaned' | Sort-Object id | ForEach-Object { [string]$_.id })
    $activeChanged = ($null -eq $previousState) -or -not (Test-SameManagedJobSet $activeSet $previousState.active)
    $orphanedChanged = ($null -eq $previousState) -or -not (Test-SameManagedJobSet $orphanedSet $previousState.orphaned)

    $parts = @()
    if (($summary.running -or $summary.starting) -and $activeChanged) {
        $active = @($summary.active | ForEach-Object { "$($_.id) [$($_.status)] $($_.name); log=$($_.logPath)" })
        $parts += "Managed jobs active after reconciliation: $($active -join ' | '). Reuse or inspect them before starting equivalents."
    }
    if ($summary.orphaned -and $orphanedChanged) {
        $parts += "$($summary.orphaned) managed job record(s) are orphaned. This is background maintenance state, not a request to inspect them; act only when the current task involves those jobs."
    }

    if ($activeChanged -or $orphanedChanged) {
        Write-ManagedJson -Path $noticeStatePath -Value ([ordered]@{
            schemaVersion = 1
            active = $activeSet
            orphaned = $orphanedSet
        })
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
