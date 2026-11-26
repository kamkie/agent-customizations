param([string]$ManagedHookId)

# Entry point of the launch guard. It runs before every shell call, so it
# settles the common case from the payload text alone and loads the full
# guard, ManagedJob.LaunchGuard.ps1, only for a call that could be denied.
$ErrorActionPreference = 'Stop'
$payloadText = [Console]::In.ReadToEnd()
if (-not $payloadText) { exit 0 }
try {
    # Undo JSON string escaping far enough to compare words: an escaped
    # backslash becomes a character no word contains, a whitespace escape
    # becomes a space, and quotes disappear, as they do when a shell joins a
    # quoted word.
    $text = $payloadText.Replace('\\', [string][char]0) -replace '\\[nrtbf]', ' ' -replace '\\/', '/' -replace '\\"|''', ''
    # The full guard can deny only a background request, a command holding one
    # of the launch words, or a rerun of a launch denied within the hour, which
    # rewrote the cache file. A \u escape could spell a launch word, so it also
    # takes the full guard. The word list must cover every trigger in
    # Get-CommandTrigger; a word that matches too often only costs time.
    $mayDeny = $text.Contains('\u') -or
        $text -match 'run_in_background(?!"\s*:\s*(?:false|null)\b)' -or
        $text -match 'Start-Process|Start-Job|new-tab|watch|bootRun|--background|--bg|(?<![\w-])-p(?![\w-])|/review' -or
        ($text -match 'npm|yarn' -and $text -match 'dev')
    if (-not $mayDeny) {
        $stateRoot = if ($env:MANAGED_JOBS_ROOT) {
            $env:MANAGED_JOBS_ROOT
        } else {
            [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), '.agent-customizations', 'managed-jobs')
        }
        $guardFile = [IO.Path]::Combine($stateRoot, 'guard', 'denied-launches.json')
        if ([IO.File]::GetLastWriteTimeUtc($guardFile) -le [datetime]::UtcNow.AddHours(-1)) { exit 0 }
    }
} catch {
    # Any doubt about the shortcut goes to the full guard.
}
& (Join-Path $PSScriptRoot 'ManagedJob.LaunchGuard.ps1') -ManagedHookId $ManagedHookId -PayloadText $payloadText
