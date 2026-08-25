Set-StrictMode -Version Latest

$script:ManagedJobStateRoot = $null

function Set-ManagedJobStateRoot {
    param([string]$Path)
    $script:ManagedJobStateRoot = if ($Path) { [IO.Path]::GetFullPath($Path) } else { $null }
}

function Get-ManagedJobAutomaticCleanupRoot {
    if ($env:MANAGED_JOBS_ROOT) {
        return [IO.Path]::GetFullPath($env:MANAGED_JOBS_ROOT)
    }
    return [IO.Path]::GetFullPath((Join-Path $HOME '.agent-customizations\managed-jobs'))
}

function Get-ManagedJobRoot {
    if ($script:ManagedJobStateRoot) {
        $root = $script:ManagedJobStateRoot
    } elseif ($env:MANAGED_JOBS_ROOT) {
        $root = [IO.Path]::GetFullPath($env:MANAGED_JOBS_ROOT)
    } else {
        $root = Get-ManagedJobAutomaticCleanupRoot
    }

    foreach ($directory in @('jobs', 'logs', 'launch', 'owners', 'control')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $root $directory) -Force
    }
    return $root
}

function Get-ManagedJobFile {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') {
        throw "Invalid managed job id: $Id"
    }
    return Join-Path (Join-Path (Get-ManagedJobRoot) 'jobs') "$Id.json"
}

function Get-ManagedJobControlFile {
    param([Parameter(Mandatory)][string]$Id)
    if ($Id -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') {
        throw "Invalid managed job id: $Id"
    }
    return Join-Path (Join-Path (Get-ManagedJobRoot) 'control') "$Id.json"
}

function Read-ManagedJob {
    param([Parameter(Mandatory)][string]$Path)
    # Move-overwrite has a tiny destination gap on Windows. Retry status reads that
    # race an atomic record update rather than surfacing a false missing-record error.
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            if ($attempt -eq 9) { throw "Managed job record not found: $Path" }
            Start-Sleep -Milliseconds 25
            continue
        }
        try {
            $text = Get-Content -LiteralPath $Path -Raw
        } catch {
            if ($attempt -eq 9) { throw }
            Start-Sleep -Milliseconds 25
            continue
        }
        if ([string]::IsNullOrWhiteSpace($text)) { throw "Managed job record is empty: $Path" }
        $job = $text | ConvertFrom-Json
        if ($null -eq $job) { throw "Managed job record is invalid: $Path" }
        return $job
    }
}

function Write-ManagedJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $directory = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $directory -Force
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-ManagedJob {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Job
    )
    Write-ManagedJson -Path $Path -Value $Job
}

function Get-ManagedJobOwnerDirectory {
    param(
        [Parameter(Mandatory)][string]$OwnerAgent,
        [Parameter(Mandatory)][string]$OwnerSessionId,
        [Parameter(Mandatory)][ValidateSet('turn', 'session')][string]$Lifetime
    )

    $agent = $OwnerAgent.Trim().ToLowerInvariant()
    if ($agent -notmatch '^[a-z0-9][a-z0-9._-]*$') {
        throw "Invalid managed-job owner agent: $OwnerAgent"
    }
    if ([string]::IsNullOrWhiteSpace($OwnerSessionId)) {
        throw 'Managed-job owner session id cannot be empty.'
    }
    $sessionBytes = [Text.Encoding]::UTF8.GetBytes($OwnerSessionId.Trim())
    $sessionHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sessionBytes)).ToLowerInvariant()
    return Join-Path (Join-Path (Join-Path (Join-Path (Get-ManagedJobRoot) 'owners') $agent) $sessionHash) $Lifetime
}

function Register-ManagedJobOwnerReference {
    param([Parameter(Mandatory)]$Job)

    if ($Job.PSObject.Properties.Name -notcontains 'lifetime' -or
        [string]$Job.lifetime -notin @('turn', 'session')) {
        return
    }
    $directory = Get-ManagedJobOwnerDirectory `
        -OwnerAgent ([string]$Job.ownerAgent) `
        -OwnerSessionId ([string]$Job.ownerSessionId) `
        -Lifetime ([string]$Job.lifetime)
    $null = New-Item -ItemType Directory -Path $directory -Force
    $reference = Join-Path $directory "$($Job.id).ref"
    Set-Content -LiteralPath $reference -Value $Job.id -Encoding utf8
}

function Unregister-ManagedJobOwnerReference {
    param([Parameter(Mandatory)]$Job)

    if ($Job.PSObject.Properties.Name -notcontains 'lifetime' -or
        [string]$Job.lifetime -notin @('turn', 'session') -or
        $Job.PSObject.Properties.Name -notcontains 'ownerAgent' -or
        $Job.PSObject.Properties.Name -notcontains 'ownerSessionId' -or
        [string]::IsNullOrWhiteSpace([string]$Job.ownerAgent) -or
        [string]::IsNullOrWhiteSpace([string]$Job.ownerSessionId)) {
        return
    }
    $directory = Get-ManagedJobOwnerDirectory `
        -OwnerAgent ([string]$Job.ownerAgent) `
        -OwnerSessionId ([string]$Job.ownerSessionId) `
        -Lifetime ([string]$Job.lifetime)
    $reference = Join-Path $directory "$($Job.id).ref"
    if (Test-Path -LiteralPath $reference -PathType Leaf) {
        Remove-Item -LiteralPath $reference -Force
    }
}

function Get-ManagedJobOwnerReferenceIds {
    param(
        [Parameter(Mandatory)][string]$OwnerAgent,
        [Parameter(Mandatory)][string]$OwnerSessionId,
        [Parameter(Mandatory)][ValidateSet('turn', 'session')][string[]]$Lifetime
    )

    foreach ($item in $Lifetime) {
        $directory = Get-ManagedJobOwnerDirectory `
            -OwnerAgent $OwnerAgent `
            -OwnerSessionId $OwnerSessionId `
            -Lifetime $item
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $directory -File -Filter '*.ref' |
            Select-Object -ExpandProperty BaseName
    }
}

function Get-ProcessSnapshot {
    param([Nullable[int]]$ProcessId)
    if (-not $ProcessId) { return $null }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return [pscustomobject]@{
            id = $process.Id
            startTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
            processName = $process.ProcessName
        }
    } catch {
        return $null
    }
}

function Test-ManagedProcessIdentity {
    param(
        [Nullable[int]]$ProcessId,
        $ExpectedStartTimeUtc
    )
    $snapshot = Get-ProcessSnapshot -ProcessId $ProcessId
    if (-not $snapshot -or -not $ExpectedStartTimeUtc) { return $false }
    $expected = if ($ExpectedStartTimeUtc -is [datetime]) {
        $ExpectedStartTimeUtc.ToUniversalTime()
    } else {
        [datetimeoffset]::Parse([string]$ExpectedStartTimeUtc).UtcDateTime
    }
    $actual = [datetimeoffset]::Parse($snapshot.startTimeUtc).UtcDateTime
    return [math]::Abs(($actual - $expected).TotalSeconds) -lt 2
}

function Get-ManagedProcessIdentity {
    param($Job)
    $snapshot = Get-ProcessSnapshot -ProcessId $Job.hostPid
    [ordered]@{
        expectedPid = $Job.hostPid
        expectedStartTimeUtc = $Job.hostStartedAtUtc
        current = $snapshot
        matches = [bool]($snapshot -and (Test-ManagedProcessIdentity -ProcessId $Job.hostPid -ExpectedStartTimeUtc $Job.hostStartedAtUtc))
    }
}

function ConvertTo-SafeJobName {
    param([Parameter(Mandatory)][string]$Name)
    $slug = $Name.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
    $slug = $slug.Trim('-')
    if (-not $slug) { $slug = 'job' }
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).TrimEnd('-') }
    return $slug
}

function Assert-SecretSafeInvocation {
    param([string[]]$Arguments, [hashtable]$Environment)
    $Arguments = @($Arguments)
    $secretName = '(?i)(?:secret|token|password|passwd|api[_-]?key|private[_-]?key|credential|cookie)$'
    $secretOption = '(?i)^--?[^=]*(?:secret|token|password|passwd|api[_-]?key|private[_-]?key|credential)(?:=|$)'
    foreach ($key in $Environment.Keys) {
        if ([string]$key -match $secretName) {
            throw "Environment key '$key' appears secret-bearing. Configure it in the parent process or a credential store so managed-jobs only inherits it."
        }
    }
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = [string]$Arguments[$index]
        if ($argument -match $secretOption -or
            ($index -gt 0 -and [string]$Arguments[$index - 1] -match $secretOption) -or
            $argument -match '(?i)^[a-z][a-z0-9+.-]*://[^/@\s]+:[^/@\s]+@' -or
            $argument -match '(?i)(authorization\s*:\s*(?:bearer|basic)|bearer\s+[a-z0-9._~-]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)' -or
            $argument -match '(?i)(?:secret|token|password|passwd|api[_-]?key|private[_-]?key|credential)\s*[:=]\s*[^\s$]+') {
            throw 'Arguments appear secret-bearing. Use inherited environment configuration, standard input, a response file outside the registry, or the target tool credential store.'
        }
    }
}

function Assert-SharedTerminalInputSafe {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$InputText)

    if ($InputText -match '(?i)(authorization\s*:\s*(?:bearer|basic)|bearer\s+[a-z0-9._~-]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)' -or
        $InputText -match '(?i)(?:^|\s)--?[^=\s]*(?:secret|token|password|passwd|api[_-]?key|private[_-]?key|credential)(?:=|\s+)\S+' -or
        $InputText -match '(?i)(?:secret|token|password|passwd|api[_-]?key|private[_-]?key|credential)\s*[:=]\s*\S+' -or
        $InputText -match '(?i)[a-z][a-z0-9+.-]*://[^/@\s]+:[^/@\s]+@') {
        throw 'Input appears credential-bearing. Authentication secrets must be typed by the user directly in the visible shared terminal.'
    }
}

function Resolve-IntelligentTerminalTools {
    if (-not $IsWindows) {
        throw 'Shared-terminal mode requires Windows.'
    }

    $packages = @(Get-AppxPackage -Name 'Microsoft.IntelligentTerminal' -ErrorAction Stop | Where-Object {
        $_.PackageFamilyName -eq 'Microsoft.IntelligentTerminal_8wekyb3d8bbwe' -and
        -not $_.IsFramework -and
        -not $_.IsResourcePackage -and
        [string]$_.Status -eq 'Ok'
    })
    $package = $packages | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if (-not $package) {
        throw 'Shared-terminal mode requires the Microsoft.IntelligentTerminal package.'
    }
    if ([version]$package.Version -lt [version]'0.2.2192.0') {
        throw "Shared-terminal mode requires Microsoft.IntelligentTerminal 0.2.2192.0 or newer; found $($package.Version)."
    }

    $packageRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$package.InstallLocation))
    $packagePrefix = $packageRoot + [IO.Path]::DirectorySeparatorChar
    $resolved = [ordered]@{
        packageVersion = [string]$package.Version
        packageRoot = $packageRoot
        comClsid = '{A2E4F6B8-1C3D-4E5F-A6B7-C8D9E0F1A2B3}'
    }
    foreach ($leaf in @('wtai.exe', 'wtcli.exe')) {
        $candidate = [IO.Path]::GetFullPath((Join-Path $packageRoot $leaf))
        if (-not $candidate.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "The installed Microsoft.IntelligentTerminal package does not provide $leaf."
        }
        $resolved[[IO.Path]::GetFileNameWithoutExtension($leaf)] = $candidate
    }
    return [pscustomobject]$resolved
}

function Resolve-RecordedIntelligentTerminalTools {
    param([Parameter(Mandatory)]$Job)

    foreach ($property in @('terminalPackageVersion', 'terminalPackageRoot', 'terminalCliPath')) {
        if ($Job.PSObject.Properties.Name -notcontains $property -or
            [string]::IsNullOrWhiteSpace([string]$Job.$property)) {
            throw 'The shared-terminal package metadata is incomplete.'
        }
    }
    try {
        $version = [version][string]$Job.terminalPackageVersion
        $packageRoot = [IO.Path]::TrimEndingDirectorySeparator(
            [IO.Path]::GetFullPath([string]$Job.terminalPackageRoot)
        )
        $cliPath = [IO.Path]::GetFullPath([string]$Job.terminalCliPath)
        $windowsAppsRoot = [IO.Path]::TrimEndingDirectorySeparator(
            [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsApps'))
        )
    } catch {
        throw 'The shared-terminal package metadata is invalid.'
    }

    $packageLeaf = [IO.Path]::GetFileName($packageRoot)
    $expectedLeafPattern = '^Microsoft\.IntelligentTerminal_' +
        [regex]::Escape($version.ToString()) +
        '_(?:x64|arm64|x86)__8wekyb3d8bbwe$'
    if (-not ([IO.Path]::GetDirectoryName($packageRoot)).Equals(
            $windowsAppsRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $packageLeaf -notmatch $expectedLeafPattern -or
        -not ([IO.Path]::GetDirectoryName($cliPath)).Equals(
            $packageRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        [IO.Path]::GetFileName($cliPath) -ne 'wtcli.exe' -or
        -not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
        throw 'The shared-terminal package metadata is invalid.'
    }
    return [pscustomobject]@{ wtcli = $cliPath }
}

function Invoke-IntelligentTerminalCliProcess {
    param(
        [Parameter(Mandatory)]$Tools,
        [Parameter(Mandatory)][string]$ComClsid,
        [string]$SessionId,
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 10
    )

    $parsedComClsid = [guid]::Empty
    if (-not [guid]::TryParse($ComClsid, [ref]$parsedComClsid)) {
        throw 'The Intelligent Terminal COM identifier is invalid.'
    }
    if ($SessionId) {
        $parsedSessionId = [guid]::Empty
        if (-not [guid]::TryParse($SessionId, [ref]$parsedSessionId)) {
            throw 'The Intelligent Terminal session identifier is invalid.'
        }
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Tools.wtcli
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['WT_COM_CLSID'] = $parsedComClsid.ToString('B')
    if ($SessionId) {
        $startInfo.Environment['WT_SESSION'] = $parsedSessionId.ToString('D')
    } else {
        $startInfo.Environment.Remove('WT_SESSION') | Out-Null
    }
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add([string]$argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    try {
        if (-not $process.Start()) { throw 'The Intelligent Terminal CLI failed to start.' }
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $exitBudget = [int][Math]::Max(1, ($deadline - [datetime]::UtcNow).TotalMilliseconds)
        if (-not $process.WaitForExit($exitBudget)) {
            try { $process.Kill($true) } catch {}
            throw 'The Intelligent Terminal CLI timed out.'
        }
        $readBudget = [int][Math]::Max(1, ($deadline - [datetime]::UtcNow).TotalMilliseconds)
        try {
            $readsCompleted = [Threading.Tasks.Task]::WaitAll(
                [Threading.Tasks.Task[]]@($standardOutputTask, $standardErrorTask),
                $readBudget
            )
        } catch {
            throw 'The Intelligent Terminal CLI output could not be read.'
        }
        if (-not $readsCompleted) {
            try { $process.StandardOutput.Close() } catch {}
            try { $process.StandardError.Close() } catch {}
            throw 'The Intelligent Terminal CLI timed out while draining output.'
        }
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            standardOutput = $standardOutputTask.GetAwaiter().GetResult()
            standardError = $standardErrorTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Get-LiveIntelligentTerminalConnection {
    param([Parameter(Mandatory)]$Tools)

    $packagePrefix = [IO.Path]::TrimEndingDirectorySeparator(
        [IO.Path]::GetFullPath([string]$Tools.packageRoot)
    ) + [IO.Path]::DirectorySeparatorChar
    $packageProcess = Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                $_.Path -and
                [IO.Path]::GetFullPath([string]$_.Path).StartsWith(
                    $packagePrefix,
                    [StringComparison]::OrdinalIgnoreCase
                )
            } catch {
                $false
            }
        } |
        Select-Object -First 1
    if (-not $packageProcess) { return $null }

    try {
        $probe = Invoke-IntelligentTerminalCliProcess `
            -Tools $Tools `
            -ComClsid $Tools.comClsid `
            -Arguments @('--json', 'list-windows')
        if ($probe.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($probe.standardOutput)) {
            return $null
        }
        $payload = $probe.standardOutput | ConvertFrom-Json
        if (@($payload.windows).Count -eq 0) { return $null }
        return [pscustomobject]@{
            tools = $Tools
            comClsid = ([guid]$Tools.comClsid).ToString('B')
        }
    } catch {
        return $null
    }
}

function Get-InvocationFingerprint {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [hashtable]$Environment
    )
    $environmentEntries = @($Environment.Keys | Sort-Object | ForEach-Object {
        [ordered]@{ name = ([string]$_).ToUpperInvariant(); value = [string]$Environment[$_] }
    })
    $canonical = [ordered]@{
        executable = $Executable.Trim().ToLowerInvariant()
        arguments = @($Arguments | ForEach-Object { [string]$_ })
        workingDirectory = ([IO.Path]::GetFullPath($WorkingDirectory)).TrimEnd('\').ToLowerInvariant()
        environment = $environmentEntries
    } | ConvertTo-Json -Depth 5 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Enable-ManagedJobProcessContainment {
    if (-not $IsWindows) {
        throw 'Managed-job process containment requires Windows.'
    }

    if (-not ('ManagedJobNativeProcessContainment' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class ManagedJobNativeProcessContainment
{
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const int JobObjectExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job,
        int informationClass,
        IntPtr information,
        uint informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static IntPtr CreateForCurrentProcess()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to create the managed-job containment object.");
        }

        try
        {
            var limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(limits);
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(limits, buffer, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to configure managed-job process containment.");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }

            if (!AssignProcessToJobObject(job, GetCurrentProcess()))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to contain the managed-job host process.");
            }

            return job;
        }
        catch
        {
            CloseHandle(job);
            throw;
        }
    }
}
'@
    }

    # Keep this raw handle open for the lifetime of the host process. Windows
    # closes it automatically on normal exit or a crash, which terminates every
    # descendant still assigned to the containment job.
    return [ManagedJobNativeProcessContainment]::CreateForCurrentProcess()
}
