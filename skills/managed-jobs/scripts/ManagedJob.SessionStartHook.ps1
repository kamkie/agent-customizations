param([string]$ManagedHookId)

$ErrorActionPreference = 'Stop'

try {
    $payloadText = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($payloadText)) {
        $payload = $payloadText | ConvertFrom-Json
        if ($payload.PSObject.Properties.Name -contains 'hook_event_name' -and
            [string]$payload.hook_event_name -ne 'SessionStart') {
            throw "Unexpected hook event: $($payload.hook_event_name)"
        }
    }

    $controller = Join-Path $PSScriptRoot 'Invoke-ManagedJob.ps1'
    $null = & $controller reconcile
    exit 0
} catch {
    $message = $_.Exception.GetBaseException().Message
    [Console]::Error.WriteLine("Managed-jobs session reconciliation failed: $message")
    exit 1
}
