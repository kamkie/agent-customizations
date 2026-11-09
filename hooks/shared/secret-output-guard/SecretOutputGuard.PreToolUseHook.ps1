param([string]$ManagedHookId)

$ErrorActionPreference = 'Stop'

# PreToolUse guard for shell tools. It denies a command that would print secret
# values into the session transcript:
#   - kubectl get secret(s) with an output format that is not provably
#     metadata-only (yaml, json, or a jsonpath, go-template, or custom-columns
#     expression that can reach .data or .stringData);
#   - az keyvault secret show without a --query that selects only non-value
#     fields;
#   - GitLab CI/CD variable reads (glab api .../variables, glab variable
#     get|export, glab variable list as JSON) that are not reduced to keys.
# A command passes when its output is piped only into a hash. Commands are
# recognized at command position, so quoted prose, search patterns, comments,
# and here-document bodies do not match. The guard fails open on its own errors.

$script:SafeVariableField = '\.(?:key|variable_type|protected|masked|hidden|raw|environment_scope|description)'
$script:KeysFilterPattern = '^\s*(?:\.\[\]\s*\|\s*' + $script:SafeVariableField +
    '|\.\[\]' + $script:SafeVariableField +
    '|' + $script:SafeVariableField +
    '|\[\s*\.\[\]\s*\|\s*' + $script:SafeVariableField + '\s*\]' +
    '|\[\s*\.\[\]' + $script:SafeVariableField + '\s*\]' +
    '|map\(\s*' + $script:SafeVariableField + '\s*\)' +
    '|keys|length)(?:\s*\|\s*(?:sort|unique|length|\.\[\]))*\s*$'
$script:SafeVariableProperties = @('key', 'variable_type', 'protected', 'masked', 'hidden', 'raw', 'environment_scope', 'description')

$script:SafeVaultField = '(?:id|name|kid|managed|contentType|attributes(?:\.[A-Za-z]+)?|tags(?:\.[A-Za-z0-9_-]+)?)'
$script:VaultQueryPattern = '^(?:' + $script:SafeVaultField +
    '|\[\s*' + $script:SafeVaultField + '(?:\s*,\s*' + $script:SafeVaultField + ')*\s*\]' +
    '|\{\s*[A-Za-z_]\w*\s*:\s*' + $script:SafeVaultField + '(?:\s*,\s*[A-Za-z_]\w*\s*:\s*' + $script:SafeVaultField + ')*\s*\})$'

$script:SafeKubePathPattern = '^[$@]?(?:\.items(?:\[[^\]]*\])?)?(?:' +
    '\.metadata\.(?:name|namespace|uid|creationTimestamp|deletionTimestamp|resourceVersion|generation|generateName|finalizers|labels|ownerReferences|managedFields)(?![A-Za-z])[^{}]*' +
    '|\.metadata\.annotations[.\[][^{}]+' +
    '|\.(?:type|kind|apiVersion|immutable))$'
$script:SafeGoActionPattern = '^(?:end|range\s+\.items|"[^"]*"|`[^`]*`' +
    '|\.(?:metadata\.(?:name|namespace|uid|creationTimestamp|resourceVersion|generation|labels(?:\.[\w-]+)?)|type|kind|apiVersion))$'

$script:KubectlValueFlags = @(
    '-n', '--namespace', '--context', '--kubeconfig', '-s', '--server', '--cluster', '--user', '--as',
    '--as-group', '--as-uid', '--token', '-l', '--selector', '--field-selector', '--request-timeout',
    '-f', '--filename', '--sort-by', '-L', '--label-columns', '--chunk-size', '--cache-dir',
    '--certificate-authority', '--client-certificate', '--client-key', '--tls-server-name',
    '--password', '--username', '-k', '--kustomize', '--raw', '--subresource', '-v', '--v',
    '-o', '--output', '--template'
)
$script:KubectlVerbs = @(
    'get', 'describe', 'create', 'delete', 'apply', 'edit', 'patch', 'replace', 'logs', 'exec', 'rollout',
    'scale', 'top', 'config', 'label', 'annotate', 'explain', 'api-resources', 'api-versions', 'auth', 'cp',
    'port-forward', 'proxy', 'run', 'expose', 'set', 'wait', 'attach', 'debug', 'diff', 'kustomize',
    'version', 'cluster-info', 'cordon', 'uncordon', 'drain', 'taint', 'certificate', 'autoscale',
    'completion', 'plugin', 'events', 'options'
)
$script:AzValueFlags = @(
    '--query', '-o', '--output', '--vault-name', '--name', '-n', '--id', '--version', '--subscription'
)
$script:GlabApiValueFlags = @(
    '-X', '--method', '-H', '--header', '-f', '--raw-field', '-F', '--field', '--form', '--input',
    '--hostname', '--placeholder', '--output'
)
$script:GlabVariableValueFlags = @(
    '-g', '--group', '-R', '--repo', '-F', '--output', '-p', '--page', '-P', '--per-page', '-s', '--scope', '--jq'
)
$script:HashCommands = @(
    'sha1sum', 'sha224sum', 'sha256sum', 'sha384sum', 'sha512sum', 'md5sum', 'b2sum', 'b3sum', 'shasum', 'md5'
)
$script:PassThroughCommands = @('base64', 'tr')
$script:ShellKeywords = @('if', 'then', 'elif', 'else', 'do', 'while', 'until', '!', 'time', 'return', 'try', 'finally')
# Wrapper commands that run another command, with their value-taking options.
$script:WrapperCommands = @{
    env = @('-u', '-C', '-S'); sudo = @('-u', '-g', '-h', '-p', '-C', '-D', '-R', '-T', '-U', '-r', '-t')
    doas = @('-u', '-C'); command = @(); exec = @('-a'); builtin = @(); nohup = @(); nice = @('-n')
    winpty = @(); stdbuf = @('-i', '-o', '-e'); timeout = @('-s', '-k'); watch = @('-n')
    xargs = @('-I', '-n', '-P', '-L', '-s', '-d', '-E', '-a')
}

$script:DenyReasons = @{
    kubectl = 'This command would print Kubernetes Secret values into the session transcript. For key names and sizes use `kubectl describe secret <name>`; for metadata use plain `kubectl get secret <name>` or an output expression that selects only metadata fields, such as `-o jsonpath=''{.metadata.name}''`; to compare a value, pipe it only into a hash, such as `kubectl get secret <name> -o jsonpath=''{.data.<key>}'' | base64 -d | sha256sum`.'
    az = 'This command would print an Azure Key Vault secret value into the session transcript. Add a `--query` that selects only non-value fields, such as `--query attributes` or `--query "{name:name, id:id}"`; to compare the value, pipe it only into a hash, such as `az keyvault secret show ... --query value -o tsv | sha256sum`.'
    glab = 'This command would print GitLab CI/CD variable values into the session transcript. List keys only: `glab variable list` in text output, `--jq ''.[].key''` on a `glab variable` command, or `glab api <path>/variables | jq -r ''.[].key''`; to compare one value, pipe it only into a hash, such as `glab variable get <key> | sha256sum`.'
}
$script:DenyReasonTail = ' Do not retry with another filter, a redirect, or a variable capture. If the user needs the value itself, they run the command in their own terminal.'

# --- Shell command-line parser -------------------------------------------------
# Splits a command line into commands, keeping pipeline links, for Bash-style or
# PowerShell-style quoting. Command and process substitutions, groups, and
# script blocks are parsed as their own command lines. Each word records whether
# it was quoted and whether it carries an unquoted output redirection.

$script:ParseText = ''
$script:ParsePosition = 0
$script:ParseDialect = 'posix'
$script:ParseLines = $null
$script:ParseDepth = 0

function New-ParseFrame {
    return @{
        commands = [Collections.Generic.List[object]]::new()
        words = [Collections.Generic.List[object]]::new()
        heredocs = [Collections.Generic.List[string]]::new()
        pending = [Collections.Generic.List[object]]::new()
        buffer = [Text.StringBuilder]::new()
        inWord = $false
        quoted = $false
        bare = $null
        redirect = $false
    }
}

function Complete-ParseWord {
    param($Frame)
    if (-not $Frame.inWord) { return }
    $text = $Frame.buffer.ToString()
    $Frame.words.Add([pscustomobject]@{
        text = $text
        quoted = $Frame.quoted
        bare = if ($Frame.quoted) { $Frame.bare } else { $text }
        redirect = $Frame.redirect
    })
    $null = $Frame.buffer.Clear()
    $Frame.inWord = $false
    $Frame.quoted = $false
    $Frame.bare = $null
    $Frame.redirect = $false
}

function Complete-ParseCommand {
    param($Frame, [string]$Separator)
    Complete-ParseWord -Frame $Frame
    if ($Frame.words.Count -eq 0) { return }
    $Frame.commands.Add([pscustomobject]@{
        words = $Frame.words.ToArray()
        sep = $Separator
        heredocs = $Frame.heredocs
    })
    $Frame.words = [Collections.Generic.List[object]]::new()
    $Frame.heredocs = [Collections.Generic.List[string]]::new()
}

function Set-ParseQuoted {
    param($Frame)
    if (-not $Frame.quoted) {
        $Frame.bare = $Frame.buffer.ToString()
        $Frame.quoted = $true
    }
    $Frame.inWord = $true
}

function Read-HeredocBodies {
    param($Frame)
    $text = $script:ParseText
    foreach ($entry in $Frame.pending) {
        $body = [Text.StringBuilder]::new()
        $bodyStart = $script:ParsePosition
        $terminated = $false
        while ($script:ParsePosition -lt $text.Length) {
            $lineEnd = $text.IndexOf("`n", $script:ParsePosition)
            if ($lineEnd -lt 0) { $lineEnd = $text.Length }
            $line = $text.Substring($script:ParsePosition, $lineEnd - $script:ParsePosition)
            $script:ParsePosition = [Math]::Min($lineEnd + 1, $text.Length)
            if ($line.Trim() -ceq $entry.delimiter) { $terminated = $true; break }
            $null = $body.Append($line).Append("`n")
        }
        if ($terminated) {
            $entry.target.Add($body.ToString())
        } else {
            # No terminator line: this was not a here-document, so the following
            # lines are still commands.
            $script:ParsePosition = $bodyStart
        }
    }
    $Frame.pending.Clear()
}

function Read-DoubleQuoted {
    param($Frame, [bool]$HereString)
    $text = $script:ParseText
    Set-ParseQuoted -Frame $Frame
    while ($script:ParsePosition -lt $text.Length) {
        $ch = $text[$script:ParsePosition]
        $next = if ($script:ParsePosition + 1 -lt $text.Length) { $text[$script:ParsePosition + 1] } else { [char]0 }
        if ($HereString) {
            if ($ch -eq '"' -and $next -eq '@' -and $script:ParsePosition -gt 0 -and $text[$script:ParsePosition - 1] -eq "`n") {
                $script:ParsePosition += 2
                return
            }
        } elseif ($ch -eq '"') {
            if ($script:ParseDialect -eq 'powershell' -and $next -eq '"') {
                $null = $Frame.buffer.Append('"')
                $script:ParsePosition += 2
                continue
            }
            $script:ParsePosition++
            return
        }
        if ($script:ParseDialect -eq 'posix' -and $ch -eq '\' -and '"$\`'.IndexOf($next) -ge 0 -and $next -ne [char]0) {
            $null = $Frame.buffer.Append($next)
            $script:ParsePosition += 2
            continue
        }
        if ($script:ParseDialect -eq 'powershell' -and $ch -eq '`' -and $next -ne [char]0) {
            $null = $Frame.buffer.Append($next)
            $script:ParsePosition += 2
            continue
        }
        if ($script:ParseDepth -lt 40) {
            if ($ch -eq '$' -and $next -eq '(') {
                $script:ParsePosition += 2
                Read-ShellLevel -Close ')'
                $null = $Frame.buffer.Append('$()')
                continue
            }
            if ($script:ParseDialect -eq 'posix' -and $ch -eq '`') {
                $script:ParsePosition++
                Read-ShellLevel -Close '`'
                $null = $Frame.buffer.Append('$()')
                continue
            }
        }
        $null = $Frame.buffer.Append($ch)
        $script:ParsePosition++
    }
}

function Read-ShellLevel {
    param([char]$Close = [char]0)
    $script:ParseDepth++
    $frame = New-ParseFrame
    $text = $script:ParseText
    $length = $text.Length
    $closed = $false
    $canNest = $script:ParseDepth -lt 40
    while ($script:ParsePosition -lt $length) {
        $position = $script:ParsePosition
        $ch = $text[$position]
        $next = if ($position + 1 -lt $length) { $text[$position + 1] } else { [char]0 }

        if ($Close -ne [char]0 -and $ch -eq $Close) {
            $script:ParsePosition++
            $closed = $true
            break
        }
        if ($ch -eq "`n" -or $ch -eq "`r") {
            $script:ParsePosition++
            Complete-ParseCommand -Frame $frame -Separator 'seq'
            if ($ch -eq "`n" -and $frame.pending.Count -gt 0) { Read-HeredocBodies -Frame $frame }
            continue
        }
        if ([char]::IsWhiteSpace($ch)) {
            Complete-ParseWord -Frame $frame
            $script:ParsePosition++
            continue
        }
        if ($ch -eq '#' -and -not $frame.inWord) {
            $lineEnd = $text.IndexOf("`n", $position)
            $script:ParsePosition = if ($lineEnd -lt 0) { $length } else { $lineEnd }
            continue
        }
        if ($ch -eq "'") {
            Set-ParseQuoted -Frame $frame
            $end = $text.IndexOf("'", $position + 1)
            if ($end -lt 0) { $end = $length }
            $null = $frame.buffer.Append($text, $position + 1, $end - $position - 1)
            $script:ParsePosition = [Math]::Min($end + 1, $length)
            continue
        }
        if ($ch -eq '"') {
            $script:ParsePosition++
            Read-DoubleQuoted -Frame $frame -HereString $false
            continue
        }
        if ($ch -eq '@' -and $script:ParseDialect -eq 'powershell' -and ($next -eq "'" -or $next -eq '"') -and
            $position + 2 -lt $length -and ($text[$position + 2] -eq "`n" -or $text.Substring($position + 2).StartsWith("`r`n"))) {
            # PowerShell here-string: literal for @'...'@, expandable for @"..."@.
            $bodyStart = $text.IndexOf("`n", $position) + 1
            if ($next -eq "'") {
                Set-ParseQuoted -Frame $frame
                $end = $text.IndexOf("`n'@", $bodyStart - 1)
                if ($end -lt 0) { $end = $length }
                $null = $frame.buffer.Append($text, $bodyStart, [Math]::Max($end - $bodyStart, 0))
                $script:ParsePosition = [Math]::Min($end + 3, $length)
            } else {
                $script:ParsePosition = $bodyStart
                Read-DoubleQuoted -Frame $frame -HereString $true
            }
            continue
        }
        if ($ch -eq '\') {
            if ($script:ParseDialect -eq 'posix' -and $next -ne [char]0) {
                $script:ParsePosition += 2
                if ($next -eq "`r" -and $script:ParsePosition -lt $length -and $text[$script:ParsePosition] -eq "`n") {
                    $script:ParsePosition++
                } elseif ($next -ne "`n" -and $next -ne "`r") {
                    $null = $frame.buffer.Append($next)
                    $frame.inWord = $true
                }
                continue
            }
            $null = $frame.buffer.Append($ch)
            $frame.inWord = $true
            $script:ParsePosition++
            continue
        }
        if ($ch -eq '`') {
            if ($script:ParseDialect -eq 'powershell') {
                $script:ParsePosition += 2
                if ($next -eq "`n" -or $next -eq "`r") {
                    if ($next -eq "`r" -and $script:ParsePosition -lt $length -and $text[$script:ParsePosition] -eq "`n") {
                        $script:ParsePosition++
                    }
                    Complete-ParseWord -Frame $frame
                } elseif ($next -ne [char]0) {
                    $null = $frame.buffer.Append($next)
                    $frame.inWord = $true
                }
                continue
            }
            if ($canNest) {
                $script:ParsePosition++
                Read-ShellLevel -Close '`'
                $null = $frame.buffer.Append('$()')
                $frame.inWord = $true
                continue
            }
        }
        if ($ch -eq '$' -and $next -eq '(' -and $canNest) {
            $script:ParsePosition += 2
            Read-ShellLevel -Close ')'
            $null = $frame.buffer.Append('$()')
            $frame.inWord = $true
            continue
        }
        if ($ch -eq '$' -and $next -eq '{') {
            $end = $text.IndexOf('}', $position)
            if ($end -lt 0) { $end = $length - 1 }
            $null = $frame.buffer.Append($text, $position, $end - $position + 1)
            $frame.inWord = $true
            $script:ParsePosition = $end + 1
            continue
        }
        if ($ch -eq '(' -and $canNest) {
            $script:ParsePosition++
            Read-ShellLevel -Close ')'
            $null = $frame.buffer.Append('()')
            $frame.inWord = $true
            continue
        }
        if ($ch -eq '{' -and $canNest) {
            # A block is parsed as its own command line. Braces attached to a word,
            # such as an unquoted jsonpath expression, also stay in that word.
            $attached = $frame.inWord
            $script:ParsePosition++
            Read-ShellLevel -Close '}'
            if ($attached) {
                $null = $frame.buffer.Append($text, $position, $script:ParsePosition - $position)
            } else {
                $null = $frame.buffer.Append('{}')
            }
            $frame.inWord = $true
            continue
        }
        if ($ch -eq ';') {
            $script:ParsePosition++
            Complete-ParseCommand -Frame $frame -Separator 'seq'
            continue
        }
        if ($ch -eq '|') {
            if ($next -eq '|') {
                $script:ParsePosition += 2
                Complete-ParseCommand -Frame $frame -Separator 'seq'
            } else {
                $script:ParsePosition += if ($next -eq '&') { 2 } else { 1 }
                Complete-ParseCommand -Frame $frame -Separator 'pipe'
            }
            continue
        }
        if ($ch -eq '&') {
            if ($next -eq '&') {
                $script:ParsePosition += 2
                Complete-ParseCommand -Frame $frame -Separator 'seq'
                continue
            }
            $last = if ($frame.inWord -and $frame.buffer.Length -gt 0) { $frame.buffer[$frame.buffer.Length - 1] } else { [char]0 }
            if ($next -eq '>' -or $last -eq '>' -or $last -eq '<') {
                $null = $frame.buffer.Append($ch)
                $frame.inWord = $true
                $script:ParsePosition++
                continue
            }
            $script:ParsePosition++
            Complete-ParseCommand -Frame $frame -Separator 'seq'
            continue
        }
        if ($ch -eq '<' -and $next -eq '<') {
            if ($position + 2 -lt $length -and $text[$position + 2] -eq '<') {
                $null = $frame.buffer.Append('<<<')
                $frame.inWord = $true
                $script:ParsePosition += 3
                continue
            }
            # Here-document: its body starts after the next line break and is data.
            $cursor = $position + 2
            if ($cursor -lt $length -and $text[$cursor] -eq '-') { $cursor++ }
            while ($cursor -lt $length -and ($text[$cursor] -eq ' ' -or $text[$cursor] -eq "`t")) { $cursor++ }
            $delimiter = [Text.StringBuilder]::new()
            if ($cursor -lt $length -and ($text[$cursor] -eq "'" -or $text[$cursor] -eq '"')) {
                $end = $text.IndexOf($text[$cursor], $cursor + 1)
                if ($end -lt 0) { $end = $length }
                $null = $delimiter.Append($text, $cursor + 1, $end - $cursor - 1)
                $cursor = [Math]::Min($end + 1, $length)
            } else {
                while ($cursor -lt $length -and -not [char]::IsWhiteSpace($text[$cursor]) -and ';|&()<>'.IndexOf($text[$cursor]) -lt 0) {
                    if ($text[$cursor] -ne '\') { $null = $delimiter.Append($text[$cursor]) }
                    $cursor++
                }
            }
            if ($delimiter.Length -gt 0) {
                $frame.pending.Add(@{ delimiter = $delimiter.ToString(); target = $frame.heredocs })
            }
            $script:ParsePosition = $cursor
            continue
        }
        if ($ch -eq '>') { $frame.redirect = $true }
        $null = $frame.buffer.Append($ch)
        $frame.inWord = $true
        $script:ParsePosition++
    }
    Complete-ParseCommand -Frame $frame -Separator $(if ($closed) { 'close' } else { 'end' })
    $script:ParseLines.Add($frame.commands.ToArray())
    $script:ParseDepth--
}

function Get-ShellLines {
    param([string]$Text, [string]$Dialect)
    $saved = @($script:ParseText, $script:ParsePosition, $script:ParseDialect, $script:ParseLines, $script:ParseDepth)
    try {
        $script:ParseText = $Text
        $script:ParsePosition = 0
        $script:ParseDialect = $Dialect
        $script:ParseLines = [Collections.Generic.List[object]]::new()
        $script:ParseDepth = 0
        Read-ShellLevel
        return , $script:ParseLines.ToArray()
    } finally {
        $script:ParseText, $script:ParsePosition, $script:ParseDialect, $script:ParseLines, $script:ParseDepth = $saved
    }
}

# --- Command analysis ----------------------------------------------------------

function Get-CommandBaseName {
    param([string]$Text)
    return (($Text -replace '^.*[\\/]', '') -replace '(?i)\.(?:exe|cmd|bat|ps1)$', '').ToLowerInvariant()
}

function Read-CommandOptions {
    param([object[]]$Words, [string[]]$ValueFlags)
    $positionals = [Collections.Generic.List[string]]::new()
    $flags = [Collections.Hashtable]::new([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $Words.Count; $i++) {
        $text = [string]$Words[$i].text
        if ($text -ceq '--') { break }
        if ($text -cmatch '^(--[A-Za-z][\w-]*)=(.*)$') {
            $flags[$Matches[1]] = [string]$Matches[2]
        } elseif ($text -cmatch '^--[A-Za-z]') {
            if ($ValueFlags -ccontains $text -and $i + 1 -lt $Words.Count) {
                $flags[$text] = [string]$Words[++$i].text
            } else {
                $flags[$text] = $true
            }
        } elseif ($text -cmatch '^-[A-Za-z]') {
            $short = $text.Substring(0, 2)
            if ($ValueFlags -ccontains $short) {
                if ($text.Length -gt 2) {
                    $flags[$short] = $text.Substring(2).TrimStart('=')
                } elseif ($i + 1 -lt $Words.Count) {
                    $flags[$short] = [string]$Words[++$i].text
                } else {
                    $flags[$short] = $true
                }
            } else {
                $flags[$text] = $true
            }
        } else {
            $positionals.Add($text)
        }
    }
    return @{ positionals = $positionals.ToArray(); flags = $flags }
}

function Get-FlagText {
    param($Flags, [string[]]$Names)
    foreach ($name in $Names) {
        if ($Flags.ContainsKey($name) -and $Flags[$name] -is [string]) { return [string]$Flags[$name] }
    }
    return $null
}

function Test-SafeKubePath {
    param([string]$Path)
    $candidate = $Path.Trim()
    if (-not $candidate) { return $false }
    if ($candidate -cnotmatch '^[.$@]') { $candidate = '.' + $candidate }
    if ($candidate.Contains('..') -or $candidate -match 'last-applied') { return $false }
    return $candidate -cmatch $script:SafeKubePathPattern
}

function Test-SafeJsonPath {
    param([string]$Expression)
    $text = $Expression.Trim()
    if (-not $text) { return $false }
    if ($text -notmatch '[{}]') { return Test-SafeKubePath -Path $text }
    $groups = [regex]::Matches($text, '\{([^{}]*)\}')
    if ($groups.Count -eq 0 -or [regex]::Replace($text, '\{[^{}]*\}', '') -match '[{}]') { return $false }
    foreach ($group in $groups) {
        $content = $group.Groups[1].Value.Trim()
        if ($content -ceq 'end' -or $content -cmatch '^"[^"]*"$' -or $content -cmatch "^'[^']*'$") { continue }
        if ($content -cmatch '^range\s+(.+)$') {
            $rangePath = $Matches[1].Trim()
            if ($rangePath -cmatch '^[$@]?\.items(?:\[\*\])?$' -or (Test-SafeKubePath -Path $rangePath)) { continue }
            return $false
        }
        if (-not (Test-SafeKubePath -Path $content)) { return $false }
    }
    return $true
}

function Test-SafeCustomColumns {
    param([string]$Expression)
    if (-not $Expression.Trim()) { return $false }
    foreach ($column in $Expression -split ',') {
        if ($column -cnotmatch '^[^:]+:(.+)$' -or -not (Test-SafeKubePath -Path $Matches[1])) { return $false }
    }
    return $true
}

function Test-SafeGoTemplate {
    param([string]$Expression)
    $actions = [regex]::Matches($Expression, '\{\{(.*?)\}\}')
    if ($actions.Count -eq 0) { return $false }
    foreach ($action in $actions) {
        $content = $action.Groups[1].Value.Trim().Trim('-').Trim()
        if ($content -cnotmatch $script:SafeGoActionPattern) { return $false }
    }
    return $true
}

# True when the kubectl arguments read Secret objects in a format that is not
# provably limited to metadata.
function Test-KubectlSecretRead {
    param([object[]]$Words)
    $options = Read-CommandOptions -Words $Words -ValueFlags $script:KubectlValueFlags
    $positionals = @($options.positionals)
    $verbIndex = -1
    for ($i = 0; $i -lt $positionals.Count; $i++) {
        if ($script:KubectlVerbs -ccontains $positionals[$i]) { $verbIndex = $i; break }
    }
    if ($verbIndex -lt 0 -or $positionals[$verbIndex] -cne 'get' -or $verbIndex + 1 -ge $positionals.Count) { return $false }
    $readsSecret = $false
    foreach ($resource in $positionals[$verbIndex + 1] -split ',') {
        $type = (($resource -split '/')[0] -split '\.')[0]
        if ($type -in @('secret', 'secrets')) { $readsSecret = $true }
    }
    if (-not $readsSecret) { return $false }

    $output = Get-FlagText -Flags $options.flags -Names @('-o', '--output')
    $template = Get-FlagText -Flags $options.flags -Names @('--template')
    if ($null -eq $output -and $null -eq $template) { return $false }
    $format = if ($null -ne $output) { $output } else { 'go-template' }
    $expression = ''
    $separator = $format.IndexOf('=')
    if ($separator -ge 0) {
        $expression = $format.Substring($separator + 1)
        $format = $format.Substring(0, $separator)
    }
    if (-not $expression -and $null -ne $template) { $expression = $template }
    switch ($format.ToLowerInvariant()) {
        { $_ -in @('json', 'yaml') } { return $true }
        { $_ -in @('jsonpath', 'jsonpath-as-json') } { return -not (Test-SafeJsonPath -Expression $expression) }
        'custom-columns' { return -not (Test-SafeCustomColumns -Expression $expression) }
        { $_ -in @('go-template', 'template') } { return -not (Test-SafeGoTemplate -Expression $expression) }
        { $_ -in @('jsonpath-file', 'custom-columns-file', 'go-template-file', 'templatefile') } { return $true }
        default { return $false }
    }
}

# True when the az arguments show a Key Vault secret without limiting the
# output to non-value fields.
function Test-AzSecretRead {
    param([object[]]$Words)
    $options = Read-CommandOptions -Words $Words -ValueFlags $script:AzValueFlags
    if (((@($options.positionals) | Select-Object -First 3) -join ' ') -cne 'keyvault secret show') { return $false }
    $output = Get-FlagText -Flags $options.flags -Names @('-o', '--output')
    if ($output -ieq 'none') { return $false }
    $query = Get-FlagText -Flags $options.flags -Names @('--query')
    return -not ($null -ne $query -and $query.Trim() -cmatch $script:VaultQueryPattern)
}

# True when the glab arguments read CI/CD variables in a form that prints values.
function Test-GlabVariableRead {
    param([object[]]$Words)
    if ($Words.Count -eq 0) { return $false }
    $subcommand = [string]$Words[0].text
    $rest = @($Words | Select-Object -Skip 1)
    if ($subcommand -ceq 'api') {
        $options = Read-CommandOptions -Words $rest -ValueFlags $script:GlabApiValueFlags
        $positionals = @($options.positionals)
        if ($positionals.Count -eq 0 -or $positionals[0] -notmatch '(?:^|/)variables(?:[/?#]|$)') { return $false }
        $flags = $options.flags
        if ($flags.ContainsKey('--silent')) { return $false }
        $method = Get-FlagText -Flags $flags -Names @('-X', '--method')
        if ($null -ne $method) { return $method -ieq 'GET' }
        foreach ($bodyFlag in @('-f', '--raw-field', '-F', '--field', '--form', '--input')) {
            if ($flags.ContainsKey($bodyFlag)) { return $false }
        }
        return $true
    }
    if ($subcommand -cin @('variable', 'var')) {
        $options = Read-CommandOptions -Words $rest -ValueFlags $script:GlabVariableValueFlags
        $positionals = @($options.positionals)
        if ($positionals.Count -eq 0) { return $false }
        $filter = Get-FlagText -Flags $options.flags -Names @('--jq')
        $keysOnly = $null -ne $filter -and $filter -cmatch $script:KeysFilterPattern
        switch -CaseSensitive ($positionals[0]) {
            { $_ -in @('get', 'export', 'ex') } { return -not $keysOnly }
            { $_ -in @('list', 'ls') } {
                $json = (Get-FlagText -Flags $options.flags -Names @('-F', '--output')) -ieq 'json'
                return ($json -or $options.flags.ContainsKey('--jq')) -and -not $keysOnly
            }
        }
    }
    return $false
}

# True when the stage sends its standard output to the next pipeline stage:
# the only redirections it may carry discard or merge standard error.
function Test-StageKeepsOutput {
    param($Stage)
    $words = $Stage.words
    for ($i = 0; $i -lt $words.Count; $i++) {
        if (-not $words[$i].redirect) { continue }
        $text = [string]$words[$i].text
        if ($text -cmatch '^2>>?$' -and $i + 1 -lt $words.Count) { $text += [string]$words[++$i].text }
        if ($text -notmatch '^2>>?(?:&1|/dev/null|\$null|nul)$') { return $false }
    }
    return $true
}

# True when the command's output flows only into a hash: optional base64 or tr
# stages, then a hash command.
function Test-PipedOnlyIntoHash {
    param([object[]]$Line, [int]$Index)
    $current = $Index
    while ($true) {
        if (-not (Test-StageKeepsOutput -Stage $Line[$current])) { return $false }
        if ($Line[$current].sep -ne 'pipe' -or $current + 1 -ge $Line.Count) { return $false }
        $current++
        $words = $Line[$current].words
        $name = Get-CommandBaseName -Text $words[0].text
        $arguments = @($words | Select-Object -Skip 1 | ForEach-Object { [string]$_.text })
        if ($script:HashCommands -contains $name) {
            return -not ($arguments -ccontains '-c' -or $arguments -ccontains '--check')
        }
        if ($name -eq 'openssl' -and $arguments.Count -gt 0 -and $arguments[0] -cmatch '^(?:dgst|md5|sha\d+|sha3-\d+|blake2\w*)$') {
            return $true
        }
        if ($script:PassThroughCommands -notcontains $name) { return $false }
    }
}

# True when the command's JSON output is piped into a filter that keeps only
# variable keys and other non-value fields.
function Test-PipedIntoKeysFilter {
    param([object[]]$Line, [int]$Index)
    if (-not (Test-StageKeepsOutput -Stage $Line[$Index])) { return $false }
    if ($Line[$Index].sep -ne 'pipe' -or $Index + 1 -ge $Line.Count) { return $false }
    $stage = $Line[$Index + 1]
    $name = Get-CommandBaseName -Text $stage.words[0].text
    $arguments = @($stage.words | Select-Object -Skip 1 | ForEach-Object { [string]$_.text })
    if ($name -eq 'jq') {
        $filter = $null
        foreach ($argument in $arguments) {
            if ($argument -cmatch '^-') {
                if ($argument -cnotmatch '^(?:-[rcMSCej]+|--raw-output|--compact-output|--monochrome-output|--color-output|--sort-keys|--exit-status|--join-output)$') { return $false }
            } elseif ($null -eq $filter) {
                $filter = $argument
            } else {
                return $false
            }
        }
        return $null -ne $filter -and $filter -cmatch $script:KeysFilterPattern
    }
    if ($name -eq 'convertfrom-json' -and $arguments.Count -eq 0 -and $stage.sep -eq 'pipe' -and $Index + 2 -lt $Line.Count) {
        $selector = $Line[$Index + 2]
        $selectorName = Get-CommandBaseName -Text $selector.words[0].text
        $selectorArguments = @($selector.words | Select-Object -Skip 1 | ForEach-Object { [string]$_.text })
        if ($selectorName -in @('select-object', 'select')) {
            if ($selectorArguments.Count -gt 0 -and $selectorArguments[0] -in @('-ExpandProperty', '-Property')) {
                $selectorArguments = @($selectorArguments | Select-Object -Skip 1)
            }
        } elseif ($selectorName -in @('foreach-object', 'foreach', '%')) {
            if ($selectorArguments.Count -ne 1) { return $false }
        } else {
            return $false
        }
        $properties = @(($selectorArguments -join ',') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($properties.Count -eq 0) { return $false }
        foreach ($property in $properties) {
            if ($script:SafeVariableProperties -cnotcontains $property) { return $false }
        }
        return $true
    }
    return $false
}

# Index of the word that is the executable: after leading assignments, shell
# keywords, and wrapper commands with their options.
function Get-ExecutableIndex {
    param([object[]]$Words)
    $index = 0
    while ($index -lt $Words.Count) {
        $word = $Words[$index]
        $text = [string]$word.text
        if ([string]$word.bare -cmatch '^[A-Za-z_][A-Za-z0-9_]*\+?=') { $index++; continue }
        if ($text -cmatch '^[$\[]' -and $index + 1 -lt $Words.Count -and -not $Words[$index + 1].quoted -and
            [string]$Words[$index + 1].text -cin @('=', '+=', '?=')) {
            $index += 2
            continue
        }
        if (-not $word.quoted -and $script:ShellKeywords -ccontains $text) { $index++; continue }
        $name = Get-CommandBaseName -Text $text
        if ($script:WrapperCommands.ContainsKey($name)) {
            $valueFlags = $script:WrapperCommands[$name]
            $index++
            while ($index -lt $Words.Count) {
                $argument = [string]$Words[$index].text
                if ($argument -ceq '--') { $index++; break }
                if ($argument -cmatch '^-') {
                    $index += if ($valueFlags -ccontains $argument) { 2 } else { 1 }
                    continue
                }
                if ([string]$Words[$index].bare -cmatch '^[A-Za-z_][A-Za-z0-9_]*=') { $index++; continue }
                if ($name -in @('timeout', 'nice', 'watch') -and $argument -cmatch '^\d+(?:\.\d+)?[smhd]?$') { $index++; continue }
                break
            }
            continue
        }
        break
    }
    return $index
}

function Get-CommandFinding {
    param([object[]]$Line, [int]$Index, [int]$Depth)
    $command = $Line[$Index]
    $words = $command.words
    $start = Get-ExecutableIndex -Words $words
    if ($start -ge $words.Count) { return $null }
    $name = Get-CommandBaseName -Text $words[$start].text
    $arguments = @($words | Select-Object -Skip ($start + 1))

    if ($name -in @('bash', 'sh', 'zsh', 'dash', 'ksh', 'pwsh', 'powershell', 'cmd')) {
        $dialect = if ($name -in @('pwsh', 'powershell')) { 'powershell' } else { 'posix' }
        for ($i = 0; $i -lt $arguments.Count - 1; $i++) {
            $flag = [string]$arguments[$i].text
            $isCommandFlag = if ($dialect -eq 'powershell') {
                $flag -imatch '^-(?:c|co|com|comm|comma|comman|command|commandwithargs|cwa)$'
            } elseif ($name -eq 'cmd') {
                $flag -imatch '^/[ck]$'
            } else {
                $flag -cmatch '^-[A-Za-z]*c$'
            }
            if (-not $isCommandFlag) { continue }
            $inner = if ($dialect -eq 'powershell' -or $name -eq 'cmd') {
                (@($arguments | Select-Object -Skip ($i + 1)) | ForEach-Object { [string]$_.text }) -join ' '
            } else {
                [string]$arguments[$i + 1].text
            }
            $finding = Get-TextFinding -Text $inner -Dialect $dialect -Depth ($Depth + 1)
            if ($finding) { return $finding }
            break
        }
        foreach ($body in $command.heredocs) {
            $finding = Get-TextFinding -Text $body -Dialect $dialect -Depth ($Depth + 1)
            if ($finding) { return $finding }
        }
        return $null
    }
    if ($name -in @('eval', 'iex', 'invoke-expression')) {
        $dialect = if ($name -eq 'eval') { 'posix' } else { 'powershell' }
        $inner = ($arguments | ForEach-Object { [string]$_.text }) -join ' '
        return Get-TextFinding -Text $inner -Dialect $dialect -Depth ($Depth + 1)
    }
    if ($name -eq 'kubectl') {
        if ((Test-KubectlSecretRead -Words $arguments) -and -not (Test-PipedOnlyIntoHash -Line $Line -Index $Index)) { return 'kubectl' }
        return $null
    }
    if ($name -eq 'az') {
        if ((Test-AzSecretRead -Words $arguments) -and -not (Test-PipedOnlyIntoHash -Line $Line -Index $Index)) { return 'az' }
        return $null
    }
    if ($name -eq 'glab') {
        if ((Test-GlabVariableRead -Words $arguments) -and
            -not (Test-PipedOnlyIntoHash -Line $Line -Index $Index) -and
            -not (Test-PipedIntoKeysFilter -Line $Line -Index $Index)) { return 'glab' }
        return $null
    }
    return $null
}

function Get-TextFinding {
    param([string]$Text, [string]$Dialect, [int]$Depth = 0)
    if ($Depth -gt 4 -or [string]::IsNullOrWhiteSpace($Text)) { return $null }
    foreach ($line in (Get-ShellLines -Text $Text -Dialect $Dialect)) {
        $commands = @($line)
        for ($i = 0; $i -lt $commands.Count; $i++) {
            $finding = Get-CommandFinding -Line $commands -Index $i -Depth $Depth
            if ($finding) { return $finding }
        }
    }
    return $null
}

# Returns 'kubectl', 'az', or 'glab' when the command would print secret
# values, otherwise $null. The PowerShell tool is read with PowerShell quoting.
# Any other shell tool is read with both quoting styles, because its shell is
# not known, and is denied when either reading finds a secret-printing command.
function Get-SecretOutputFinding {
    param([string]$Command, [string]$ToolName)
    # Cheap exit for unrelated commands. Quote and escape characters are removed
    # first, because a shell joins fragments such as sec""ret into one word.
    if (($Command -replace '[''"\\`]|\r?\n', '') -notmatch '(?i)secret|variable|glab') { return $null }
    $dialects = if ($ToolName -eq 'PowerShell') { @('powershell') } else { @('posix', 'powershell') }
    foreach ($dialect in $dialects) {
        $finding = Get-TextFinding -Text $Command -Dialect $dialect
        if ($finding) { return $finding }
    }
    return $null
}

function Get-SecretOutputDenyReason {
    param([string]$Finding)
    return $script:DenyReasons[$Finding] + $script:DenyReasonTail
}

# Dot-sourcing loads the functions for tests without reading a hook payload.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    $payloadText = [Console]::In.ReadToEnd()
    if (-not $payloadText) { exit 0 }
    $payload = $payloadText | ConvertFrom-Json
    $toolInput = $payload.tool_input
    $command = if ($toolInput -is [string]) {
        [string]$toolInput
    } elseif ($toolInput.command -is [array]) {
        # An argument vector: quote each element so it stays one word.
        (@($toolInput.command) | ForEach-Object { "'" + ([string]$_).Replace("'", "'\''") + "'" }) -join ' '
    } elseif ($toolInput.command) {
        [string]$toolInput.command
    } else {
        ''
    }
    if (-not $command) { exit 0 }

    $finding = Get-SecretOutputFinding -Command $command -ToolName ([string]$payload.tool_name)
    if (-not $finding) { exit 0 }

    [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = Get-SecretOutputDenyReason -Finding $finding
        }
    } | ConvertTo-Json -Depth 6 -Compress
} catch {
    [ordered]@{ systemMessage = "Secret-output guard failed open: $($_.Exception.Message)" } | ConvertTo-Json -Compress
}
