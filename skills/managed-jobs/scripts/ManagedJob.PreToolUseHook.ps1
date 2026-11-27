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
    # quoted word. Any backslash left after that is another escape.
    $text = $payloadText.Replace('\\', [string][char]0) -replace '\\[nrt]', ' ' -replace '\\/', '/' -replace '\\"|''', ''
    # The full guard can deny only a background request, a command holding one
    # of the launch words, or a rerun of a launch denied within the hour. Its
    # string comparisons ignore characters such as a soft hyphen or a control
    # character inside a launch word, so a payload with anything but printable
    # ASCII and JSON whitespace, or with any other escape, also takes the full
    # guard. The word list must cover every trigger in Get-CommandTrigger; a
    # word that matches too often only costs time.
    $mayDeny = $payloadText -cmatch '[^\x20-\x7E\r\n\t]' -or $text.Contains('\') -or
        $text -match 'run_in_background(?!"\s*:\s*(?:false|null)\b)' -or
        $text -match 'Start-Process|Start-Job|new-tab|watch|bootRun|--background|--bg|(?<![\w-])-p(?![\w-])|/review' -or
        ($text -match 'npm|yarn' -and $text -match 'dev')
    if (-not $mayDeny) {
        # A hook that is recording a denial holds the cache mutex before it
        # rewrites the file, so an existing mutex sends this call to the full
        # guard, which waits for the writer. ManagedJob.LaunchGuard.ps1 builds
        # the mutex name from the same normalized path. Cmdlets are avoided
        # here: loading their module costs more than everything else combined.
        $stateRoot = if ($env:MANAGED_JOBS_ROOT) {
            $env:MANAGED_JOBS_ROOT
        } else {
            [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), '.agent-customizations\managed-jobs')
        }
        $guardFile = [IO.Path]::GetFullPath([IO.Path]::Combine($stateRoot, 'guard', 'denied-launches.json'))
        $guardLockName = 'Local\managed-jobs-guard-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($guardFile.ToLowerInvariant()))).Substring(0, 32)
        $pendingWriter = $null
        $writerPresent = [Threading.Mutex]::TryOpenExisting($guardLockName, [ref]$pendingWriter)
        if ($pendingWriter) { $pendingWriter.Dispose() }
        if (-not $writerPresent -and [IO.File]::GetLastWriteTimeUtc($guardFile) -le [datetime]::UtcNow.AddHours(-1)) { exit 0 }
    }
} catch {
    # Any doubt about the shortcut goes to the full guard.
}
& (Join-Path $PSScriptRoot 'ManagedJob.LaunchGuard.ps1') -ManagedHookId $ManagedHookId -PayloadText $payloadText
