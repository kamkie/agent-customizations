param([string]$ManagedHookId)

$ErrorActionPreference = 'Stop'

# The index of the `)` that closes a `$(` whose content starts at $Start, or
# the text length when it is not closed. Parentheses inside quotes or after a
# backslash do not count.
function Get-SubstitutionEnd {
    param([string]$Text, [int]$Start)
    $depth = 1
    $quote = [char]0
    for ($i = $Start; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($quote -ne [char]0) {
            if ($ch -eq $quote) {
                $quote = [char]0
            } elseif ($quote -eq '"' -and $ch -eq '\') {
                $i++
            } elseif ($quote -eq '"' -and $ch -eq '$' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '(') {
                $i = Get-SubstitutionEnd -Text $Text -Start ($i + 2)
            }
            continue
        }
        if ($ch -eq '\') { $i++; continue }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
        if ($ch -eq '(') { $depth++ }
        elseif ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) { return $i }
        }
    }
    return $Text.Length
}

# Split a command line into shell segments and each segment into tokens.
# Quotes group a token; `;`, `|`, `&`, `(`, `{`, and newlines end a segment.
# Each token records whether it was quoted so a shell command string can be
# inspected as a nested command line, and whether any part was double-quoted,
# where a shell still runs `$(...)` substitutions. -LiteralHash reads `#` as
# plain text, for cmd.exe, which has no `#` comments.
function Get-ShellSegments {
    param([string]$Text, [switch]$LiteralHash)
    $segments = [Collections.Generic.List[object]]::new()
    $tokens = [Collections.Generic.List[object]]::new()
    $buffer = [Text.StringBuilder]::new()
    $quote = [char]0
    $quoted = $false
    $expandable = $false
    # Unquoted text before the first quote, so NAME="value" still reads as an
    # assignment even though its value is quoted.
    $unquotedPrefix = $null
    $chars = $Text.ToCharArray()
    # Iterate one past the end so a sentinel flushes the final token and segment.
    for ($i = 0; $i -le $chars.Length; $i++) {
        $atEnd = $i -eq $chars.Length
        $ch = if ($atEnd) { [char]0 } else { $chars[$i] }
        if (-not $atEnd -and $quote -ne [char]0) {
            if ($ch -eq $quote) {
                $quote = [char]0
            } elseif ($quote -eq '"' -and $ch -eq '$' -and $i + 1 -lt $chars.Length -and $chars[$i + 1] -eq '(') {
                # Keep a substitution whole, with its own quotes: they do not
                # close the word's quote.
                $close = [math]::Min((Get-SubstitutionEnd -Text $Text -Start ($i + 2)), $chars.Length - 1)
                $null = $buffer.Append($Text, $i, $close - $i + 1)
                $i = $close
            } else {
                $null = $buffer.Append($ch)
            }
            continue
        }
        # A backslash (Bash) or backtick (PowerShell) before a line break continues
        # the current command; consume the pair as plain whitespace.
        if (-not $atEnd -and ($ch -eq '\' -or $ch -eq '`') -and $i + 1 -lt $chars.Length -and ($chars[$i + 1] -eq "`n" -or $chars[$i + 1] -eq "`r")) {
            $i++
            if ($chars[$i] -eq "`r" -and $i + 1 -lt $chars.Length -and $chars[$i + 1] -eq "`n") { $i++ }
            $ch = ' '
        }
        # A `#` that starts a word begins a comment: skip to the end of the line so
        # an apostrophe in the comment cannot open a quote over the next command.
        if (-not $atEnd -and -not $LiteralHash -and $ch -eq '#' -and $buffer.Length -eq 0 -and -not $quoted) {
            while ($i + 1 -lt $chars.Length -and $chars[$i + 1] -ne "`n" -and $chars[$i + 1] -ne "`r") { $i++ }
            continue
        }
        if (-not $atEnd -and ($ch -eq '"' -or $ch -eq "'")) {
            $quote = $ch
            if (-not $quoted) { $unquotedPrefix = $buffer.ToString() }
            $quoted = $true
            if ($ch -eq '"') { $expandable = $true }
            continue
        }
        $isSeparator = $atEnd -or ";|&(){}`r`n".IndexOf($ch) -ge 0
        if ($isSeparator -or [char]::IsWhiteSpace($ch)) {
            if ($buffer.Length -gt 0 -or $quoted) {
                $tokens.Add([pscustomobject]@{
                    text = $buffer.ToString()
                    quoted = $quoted
                    expandable = $expandable
                    unquotedPrefix = if ($quoted) { $unquotedPrefix } else { $buffer.ToString() }
                })
                $null = $buffer.Clear()
                $quoted = $false
                $expandable = $false
                $unquotedPrefix = $null
            }
            if ($isSeparator -and $tokens.Count -gt 0) {
                $segments.Add(@($tokens.ToArray()))
                $tokens.Clear()
            }
            continue
        }
        $null = $buffer.Append($ch)
    }
    return $segments.ToArray()
}

$shellNames = '^(?:bash|sh|zsh|pwsh|powershell|cmd)$'
$evaluatorNames = '^(?:Invoke-Expression|iex|eval)$'

# The command a segment runs: its executable after leading VAR=value
# assignments, a PowerShell `$name =` assignment, and words that only prefix a
# command (`env`, `nohup`, shell keywords). Returns $null when the segment only
# assigns a value, so a quoted string that mentions a launch is not a command.
function Get-SegmentCommand {
    param([object[]]$Segment)
    $index = 0
    $assigned = $false
    $name = $null
    # A PowerShell variable, with an optional [type] before it.
    $variable = '^(?:\[[^\]]+\])*\$[\w:.\[\]{}]+'
    while ($index -lt $Segment.Count) {
        $token = $Segment[$index]
        if ($token.unquotedPrefix -match '^[A-Za-z_][A-Za-z0-9_]*\+?=') { $index++; continue }
        if ($token.unquotedPrefix -match ($variable + '\+?=')) {
            # $name=value in one word: an unquoted value is the command it runs.
            if ($token.quoted) { return $null }
            $name = $token.text -replace ($variable + '\+?='), ''
            break
        }
        if (-not $token.quoted) {
            if ($token.text -in @('&', '.', '!', 'if', 'then', 'else', 'elif', 'do', 'while', 'until', 'return')) {
                $index++
                continue
            }
            if ($token.text -in @('env', 'nohup', 'time', 'exec', 'command', 'sudo', 'setsid', 'timeout', 'nice', 'stdbuf', 'winpty')) {
                # Skip the wrapper with its flags and a timeout duration.
                $index++
                while ($index -lt $Segment.Count -and -not $Segment[$index].quoted -and $Segment[$index].text -match '^(?:-.*|\d+(?:\.\d+)?[smhd]?)$') { $index++ }
                continue
            }
            if ($token.text -ieq 'start') {
                # cmd's start runs the command after its /flags and quoted title.
                $index++
                if ($index -lt $Segment.Count -and $Segment[$index].quoted) { $index++ }
                while ($index -lt $Segment.Count -and -not $Segment[$index].quoted -and $Segment[$index].text -match '^/[A-Za-z]+$') { $index++ }
                continue
            }
            if ($token.text -match ($variable + '$') -and $index + 1 -lt $Segment.Count -and
                -not $Segment[$index + 1].quoted -and $Segment[$index + 1].text -match '^[-+*/]?=$') {
                $index += 2
                $assigned = $true
                continue
            }
        }
        break
    }
    if ($index -ge $Segment.Count) { return $null }
    if ($null -eq $name) {
        if ($assigned -and $Segment[$index].quoted) { return $null }
        $name = $Segment[$index].text
    }
    $baseName = $name -replace '^.*[\\/]', ''
    return [pscustomobject]@{
        stem = $baseName -replace '(?i)\.(?:exe|cmd|bat|ps1)$', ''
        arguments = @($Segment | Select-Object -Skip ($index + 1))
    }
}

# The pipeline around position $Index of a line: the text between the nearest
# `;`, `&&`, or `||` on each side, ignoring those inside quotes.
function Get-PipelineText {
    param([string]$Line, [int]$Index)
    $start = 0
    $end = $Line.Length
    $quote = [char]0
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($quote -ne [char]0) {
            if ($ch -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
        $width = if ($ch -eq ';') { 1 }
            elseif (($ch -eq '&' -or $ch -eq '|') -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq $ch) { 2 }
            else { 0 }
        if ($width -eq 0) { continue }
        if ($i -ge $Index) { $end = $i; break }
        $start = $i + $width
        $i += $width - 1
    }
    return $Line.Substring($start, $end - $start)
}

# True when the word is the flag after which a shell takes a command string.
function Test-CommandFlag {
    param([string]$Stem, [string]$Word)
    return ($Word -imatch '^(?:-c|-Command|/c|/k)$' -or ($Stem -imatch '^(?:bash|sh|zsh)$' -and $Word -cmatch '^-[A-Za-z]*c$'))
}

# True when a shell or evaluator takes its program from standard input or the
# pipeline, so text fed to it runs as commands. False when it runs a command
# string or a script file: its input is then data for that program.
function Test-ReadsProgramFromInput {
    param([string]$Stem, [object[]]$Arguments)
    if ($Stem -ieq 'cmd') {
        return (@($Arguments | Where-Object { -not $_.quoted -and $_.text -imatch '^/[ck]$' }).Count -eq 0)
    }
    $posix = $Stem -imatch '^(?:bash|sh|zsh)$'
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $word = $Arguments[$i].text
        if ($Arguments[$i].unquotedPrefix -match '^\d*[<>]') {
            # A redirection; a bare operator takes the next word as its target.
            if ($word -match '^\d*[<>]+$') { $i++ }
            continue
        }
        # A script file or a command string: input is data.
        if ($Arguments[$i].quoted -or $word -notmatch '^[-+]') { return $false }
        if ($posix) {
            if ($word -cmatch '^-[A-Za-z]*c[A-Za-z]*$') { return $false }
            if ($word -cmatch '^-[A-Za-z]*s[A-Za-z]*$') { return $true }
            if ($word -cmatch '^(?:[-+]o|--rcfile|--init-file)$') { $i++ }
        } else {
            if ($word -imatch '^-(?:c|Command|CommandWithArgs|cwa|f|File)$') {
                return ($i + 1 -lt $Arguments.Count -and $Arguments[$i + 1].text -eq '-')
            }
            if ($word -imatch '^-(?:e|ec|EncodedCommand)$') { return $false }
            if ($word -imatch '^-(?:ExecutionPolicy|ep|ex|WorkingDirectory|wd|ConfigurationName|CustomPipeName|SettingsFile|InputFormat|OutputFormat|WindowStyle)$') { $i++ }
        }
    }
    return $true
}

# True when the here-document or here-string at position $Index of the line
# runs as commands: a shell or evaluator in its pipeline reads its program
# from input, takes the here-string ($Placeholder) as its command string, or
# runs the command substitution that contains the here-document.
function Test-ShellRecipient {
    param([string]$Line, [int]$Index, [string]$Placeholder)
    # Only the pipeline that receives the text counts: a shell elsewhere on the
    # line, such as a syntax check after `&&`, does not run it.
    $pipeline = Get-PipelineText -Line $Line -Index $Index
    $before = $Line.Substring(0, $Index)
    $opened = $before.LastIndexOf('$(')
    $inSubstitution = $opened -ge 0 -and (Get-SubstitutionEnd -Text $before -Start ($opened + 2)) -ge $before.Length
    foreach ($segment in Get-ShellSegments -Text $pipeline) {
        $segmentCommand = Get-SegmentCommand -Segment $segment
        if (-not $segmentCommand) { continue }
        $stem = $segmentCommand.stem
        $arguments = $segmentCommand.arguments
        if ($stem -imatch $evaluatorNames) {
            if ($inSubstitution -or $arguments.Count -eq 0 -or ($Placeholder -and @($arguments | Where-Object { $_.text -eq $Placeholder }).Count -gt 0)) { return $true }
        } elseif ($stem -imatch $shellNames) {
            if ($inSubstitution -or (Test-ReadsProgramFromInput -Stem $stem -Arguments $arguments)) { return $true }
            for ($i = 1; $Placeholder -and $i -lt $arguments.Count; $i++) {
                if ($arguments[$i].text -eq $Placeholder -and (Test-CommandFlag -Stem $stem -Word $arguments[$i - 1].text)) { return $true }
            }
        }
    }
    return $false
}

# The commands a shell runs while it expands text: the content of each
# `$(...)` and, with -Backticks (Bash), of each backtick pair.
function Get-Substitutions {
    param([string]$Text, [switch]$Backticks)
    $found = [Collections.Generic.List[string]]::new()
    $start = $Text.IndexOf('$(')
    while ($start -ge 0) {
        $end = Get-SubstitutionEnd -Text $Text -Start ($start + 2)
        $found.Add($Text.Substring($start + 2, $end - $start - 2))
        $start = if ($end + 1 -lt $Text.Length) { $Text.IndexOf('$(', $end + 1) } else { -1 }
    }
    if ($Backticks) {
        foreach ($pair in [regex]::Matches($Text, '`([^`]+)`')) { $found.Add($pair.Groups[1].Value) }
    }
    return $found.ToArray()
}

# Remove here-document and PowerShell here-string bodies from the command text:
# they are data (a commit message, a file body), not commands. What a body
# still runs is returned separately so it is inspected as a command line: the
# whole body when a shell receives it, otherwise the substitutions of an
# expandable body (an unquoted delimiter, or a double-quoted here-string).
function Get-InspectableText {
    param([string]$Text)
    $lines = [Collections.Generic.List[string]]::new([string[]]($Text -split "`r?`n"))
    $kept = [Collections.Generic.List[string]]::new()
    $shellBodies = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $hereString = [regex]::Match($line, '@([''"])\s*$')
        if ($hereString.Success) {
            $terminator = $hereString.Groups[1].Value + '@'
            $end = $i + 1
            while ($end -lt $lines.Count -and -not $lines[$end].StartsWith($terminator)) { $end++ }
            if ($end -lt $lines.Count) {
                # Rejoin the text around the body and examine that line again: it
                # may open another here-string.
                $joined = $line.Substring(0, $hereString.Index) + "'<here-string>'" + $lines[$end].Substring(2)
                $body = @($lines.GetRange($i + 1, $end - $i - 1)) -join "`n"
                if (Test-ShellRecipient -Line $joined -Index $hereString.Index -Placeholder '<here-string>') {
                    $shellBodies.Add($body)
                } elseif ($hereString.Groups[1].Value -eq '"') {
                    foreach ($substitution in Get-Substitutions -Text $body) { $shellBodies.Add($substitution) }
                }
                $lines[$end] = $joined
                $i = $end - 1
                continue
            }
        }
        $kept.Add($line)
        foreach ($hereDocument in [regex]::Matches($line, '(?<!<)<<(?!<)[-~]?\s*([''"]?)([A-Za-z_]\w*)\1')) {
            $delimiter = $hereDocument.Groups[2].Value
            $end = $i + 1
            while ($end -lt $lines.Count -and $lines[$end].Trim() -cne $delimiter) { $end++ }
            # Without its terminator this is not a here-document: keep the lines.
            if ($end -ge $lines.Count) { break }
            $body = @($lines.GetRange($i + 1, $end - $i - 1)) -join "`n"
            if (Test-ShellRecipient -Line $line -Index $hereDocument.Index) {
                $shellBodies.Add($body)
            } elseif (-not $hereDocument.Groups[1].Value) {
                foreach ($substitution in Get-Substitutions -Text $body -Backticks) { $shellBodies.Add($substitution) }
            }
            $i = $end
        }
    }
    return [pscustomobject]@{ text = $kept -join "`n"; shellBodies = $shellBodies.ToArray() }
}

# The command line handed to a shell after -c, -Command, or /c. A quoted first
# word is the whole script; otherwise the remaining words are, with quoted
# words kept as single words so their content is not read as commands.
function Get-NestedCommandText {
    param([object[]]$Tokens)
    if ($Tokens.Count -eq 0) { return '' }
    if ($Tokens[0].quoted) { return $Tokens[0].text }
    return (@($Tokens | ForEach-Object {
        if ($_.quoted) { '"' + ($_.text -replace '[''"\r\n]', ' ') + '"' } else { $_.text }
    }) -join ' ')
}

# The launch a command performs, as a short label for the denial, or $null.
function Get-CommandTrigger {
    param([string]$Stem, [object[]]$Arguments, [int]$Depth)
    $words = @($Arguments | ForEach-Object { $_.text })
    if ($Stem -in @('Start-Process', 'Start-Job')) { return $Stem }
    if ($Stem -ieq 'wt' -and $words -contains 'new-tab') { return 'wt new-tab' }
    if ($Stem -ieq 'dotnet' -and $words.Count -gt 0 -and $words[0] -ieq 'watch') { return 'dotnet watch' }
    if ($Stem -ieq 'gradlew' -and ($words -match '(?:^|:)bootRun\b')) { return 'gradlew bootRun' }
    if ($Stem -in @('vite', 'webpack', 'tsc') -and ($words -match '^--watch\b')) { return "$Stem --watch" }
    if ($Stem -ieq 'claude') {
        if ($words -eq '-p') { return 'claude -p' }
        if ($words -match '^/review\b') { return 'claude /review' }
    }
    if ($Stem -in @('npm', 'pnpm', 'yarn', 'npx', 'bunx', 'corepack')) {
        if ($Stem -in @('npm', 'pnpm', 'yarn')) {
            if ($words.Count -gt 0 -and $words[0] -match '^dev\b') { return "$Stem $($words[0])" }
            for ($i = 0; $i -lt $words.Count - 1; $i++) {
                if ($words[$i] -ieq 'run' -and $words[$i + 1] -match '^dev\b') { return "$Stem run $($words[$i + 1])" }
            }
        }
        # A package runner runs the command string after -c or --call.
        for ($i = 0; $i -lt $Arguments.Count - 1; $i++) {
            if ($Arguments[$i].quoted -or $words[$i] -cnotmatch '^(?:-c|--call)$') { continue }
            $inner = Get-LaunchTrigger -Text $words[$i + 1] -Depth ($Depth + 1)
            if ($inner) { return $inner }
            break
        }
        # A package runner runs the tool named in its arguments, which may be
        # another package runner. Inspect the first tool that can launch, once,
        # so a long argument list stays linear.
        for ($i = 0; $i -lt $Arguments.Count -and $Depth -lt 3; $i++) {
            if ($Arguments[$i].quoted) { continue }
            $tool = $words[$i] -replace '(?i)\.(?:exe|cmd|bat|ps1)$', ''
            if ($tool -inotmatch '^(?:vite|webpack|tsc|claude|dotnet|gradlew|wt|npm|pnpm|yarn|npx|bunx|corepack)$' -and $tool -inotmatch $shellNames) { continue }
            $inner = Get-CommandTrigger -Stem $tool -Arguments @($Arguments | Select-Object -Skip ($i + 1)) -Depth ($Depth + 1)
            if ($inner) { return $inner }
            break
        }
    }
    $nested = [Collections.Generic.List[string]]::new()
    if ($Stem -imatch $shellNames) {
        $commandFound = $false
        # A Bash here-string (`<<< text`) is the shell's standard input: its
        # program when the shell reads one from input, otherwise data.
        $readsInput = Test-ReadsProgramFromInput -Stem $Stem -Arguments $Arguments
        for ($i = 0; $i -lt $Arguments.Count; $i++) {
            if ($Arguments[$i].unquotedPrefix -like '<<<*') {
                if ($words[$i].Length -gt 3) {
                    if ($readsInput) { $nested.Add($words[$i].Substring(3)) }
                } elseif ($i + 1 -lt $Arguments.Count) {
                    $i++
                    if ($readsInput) { $nested.Add($words[$i]) }
                }
                continue
            }
            if ($commandFound -or $Arguments[$i].quoted -or $i + 1 -ge $Arguments.Count) { continue }
            if (Test-CommandFlag -Stem $Stem -Word $words[$i]) {
                $nested.Add((Get-NestedCommandText -Tokens @($Arguments | Select-Object -Skip ($i + 1))))
                $commandFound = $true
            }
        }
    } elseif ($Stem -imatch $evaluatorNames) {
        $skip = if ($words.Count -gt 0 -and -not $Arguments[0].quoted -and $words[0] -imatch '^-Command$') { 1 } else { 0 }
        $nested.Add((Get-NestedCommandText -Tokens @($Arguments | Select-Object -Skip $skip)))
    }
    foreach ($commandText in $nested) {
        # cmd.exe has no `#` comments, so `#` must not hide the rest of its line.
        $inner = Get-LaunchTrigger -Text $commandText -Depth ($Depth + 1) -LiteralHash:($Stem -ieq 'cmd')
        if ($inner) { return $inner }
    }
    # A background flag counts as an argument of a command, not as text handed
    # to a search or print tool.
    if ($Stem -notin @('grep', 'egrep', 'fgrep', 'rg', 'ag', 'findstr', 'Select-String', 'sls', 'echo', 'printf', 'Write-Output', 'Write-Host', 'sed', 'awk', 'cat')) {
        $flag = @($words -match '^--(?:background|bg)(?:=|$)') | Select-Object -First 1
        if ($flag) { return ($flag -replace '=.*$', '') }
    }
    return $null
}

# The first detached or long-running launch the command line performs, or
# $null. A launch is recognized where a command runs: as the executable of a
# shell segment with its arguments, including a command string handed to a
# shell with -c, -Command, or /c, and a `$(...)` substitution inside a
# double-quoted word. Text that only mentions a launch (a search pattern, a
# commit message, a file body, a path) is not one.
function Get-LaunchTrigger {
    param([string]$Text, [int]$Depth = 0, [switch]$LiteralHash)
    if ($Depth -gt 3 -or [string]::IsNullOrWhiteSpace($Text)) { return $null }
    $source = Get-InspectableText -Text $Text
    foreach ($segment in Get-ShellSegments -Text $source.text -LiteralHash:$LiteralHash) {
        $segmentCommand = Get-SegmentCommand -Segment $segment
        if ($segmentCommand) {
            $trigger = Get-CommandTrigger -Stem $segmentCommand.stem -Arguments $segmentCommand.arguments -Depth $Depth
            if ($trigger) { return $trigger }
        }
        foreach ($token in $segment) {
            if (-not $token.expandable -or -not $token.text.Contains('$(')) { continue }
            foreach ($substitution in Get-Substitutions -Text $token.text) {
                $trigger = Get-LaunchTrigger -Text $substitution -Depth ($Depth + 1)
                if ($trigger) { return $trigger }
            }
        }
    }
    foreach ($body in $source.shellBodies) {
        $trigger = Get-LaunchTrigger -Text $body -Depth ($Depth + 1)
        if ($trigger) { return $trigger }
    }
    return $null
}

# True when every command in the text is the managed-jobs controller reading
# job state (wait, status, logs), apart from naming the controller script,
# capturing the result, and formatting it. Such a call is already managed, so
# it may run in the background; anything else on the line keeps the denial.
function Test-ControllerMonitorOnly {
    param([string]$Text)
    # A substitution inside an argument would run another command.
    if ($Text -match '\$\(|`') { return $false }
    $controllerPattern = '(?i)(?:^|[\\/])Invoke-ManagedJob\.ps1$'
    $variablePattern = '^\$\{?(?<name>[A-Za-z_]\w*)\}?$'
    $formatters = @('Out-String', 'ConvertFrom-Json', 'ConvertTo-Json', 'Select-Object', 'Format-List', 'Format-Table', 'Out-Host', 'cd', 'Set-Location')
    $controllerVariables = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $isController = {
        param($Token)
        if ($Token.text -match $controllerPattern) { return $true }
        $variable = [regex]::Match($Token.text, $variablePattern)
        return ($variable.Success -and $controllerVariables.Contains($variable.Groups['name'].Value))
    }
    $monitorCalls = 0
    foreach ($segment in Get-ShellSegments -Text ($Text -replace '\d?>&\d', ' ')) {
        $first = $segment[0]
        if ($segment.Count -eq 1) {
            $definition = [regex]::Match($first.text, '^\$?(?<name>[A-Za-z_]\w*)=(?<value>.+)$')
            if ($definition.Success -and $definition.Groups['value'].Value -match $controllerPattern) {
                $null = $controllerVariables.Add($definition.Groups['name'].Value)
                continue
            }
        }
        $target = [regex]::Match($first.text, $variablePattern)
        if (-not $first.quoted -and $target.Success -and $segment.Count -ge 2 -and -not $segment[1].quoted -and $segment[1].text -eq '=') {
            $name = $target.Groups['name'].Value
            # `$result = (` or `$result = &`: the command follows in its own segment.
            if ($segment.Count -eq 2) { $null = $controllerVariables.Remove($name); continue }
            $joinsPath = $segment.Count -eq 5 -and -not $segment[2].quoted -and $segment[2].text -ieq 'Join-Path'
            if (($segment.Count -eq 3 -or $joinsPath) -and $segment[-1].text -match $controllerPattern) {
                $null = $controllerVariables.Add($name)
                continue
            }
            return $false
        }
        $index = 0
        while ($index -lt $segment.Count -and $segment[$index].unquotedPrefix -match '^[A-Za-z_][A-Za-z0-9_]*=') { $index++ }
        if ($index -ge $segment.Count) { return $false }
        $executable = $segment[$index]
        $rest = @($segment | Select-Object -Skip ($index + 1))
        $baseName = $executable.text -replace '^.*[\\/]', ''
        if (-not $executable.quoted -and $baseName -in $formatters) { continue }
        if (-not (& $isController $executable)) {
            # pwsh [-NoProfile ...] -File <controller> <action>
            if ($executable.quoted -or $baseName -inotmatch '^(?:pwsh|powershell)(?:\.exe)?$') { return $false }
            $i = 0
            while ($i -lt $rest.Count -and $rest[$i].text -imatch '^-(?:NoProfile|NoLogo|NonInteractive|ExecutionPolicy)$') {
                $i += if ($rest[$i].text -ieq '-ExecutionPolicy') { 2 } else { 1 }
            }
            if ($i + 1 -ge $rest.Count -or $rest[$i].text -ine '-File' -or -not (& $isController $rest[$i + 1])) { return $false }
            $rest = @($rest | Select-Object -Skip ($i + 2))
        }
        if ($rest.Count -eq 0 -or $rest[0].text -notin @('wait', 'status', 'logs')) { return $false }
        $monitorCalls++
    }
    return ($monitorCalls -gt 0)
}

try {
    $payloadText = [Console]::In.ReadToEnd()
    if (-not $payloadText) { exit 0 }
    $payload = $payloadText | ConvertFrom-Json
    $command = if ($payload.tool_input -is [string]) {
        [string]$payload.tool_input
    } elseif ($payload.tool_input.command) {
        [string]$payload.tool_input.command
    } else {
        ''
    }
    if (-not $command) { exit 0 }

    $explicitBypass = $command -match '(?:codex-)?managed-jobs:\s*allow-direct'
    if ($explicitBypass) { exit 0 }

    $backgroundRequested = $payload.tool_input -isnot [string] -and
        $payload.tool_input.PSObject.Properties['run_in_background'] -and
        [bool]$payload.tool_input.run_in_background

    # Launches are recognized at command position, not as substrings, so text
    # that only mentions one passes.
    $matched = Get-LaunchTrigger -Text $command

    # The controller exemption never covers a compound command that also uses a
    # raw detach primitive. A natively backgrounded call passes only when all it
    # does is read job state through the controller.
    $usesController = $command -match 'Invoke-ManagedJob\.ps1|managed-jobs[\\/]scripts'
    if ($usesController -and -not $matched -and
        (-not $backgroundRequested -or (Test-ControllerMonitorOnly -Text $command))) { exit 0 }

    # Retry memory is best-effort: a cache failure — including an unavailable
    # state-root drive — must weaken only retry detection, never a pattern or
    # background denial.
    $nowUtc = [datetime]::UtcNow
    $guardFile = $null
    $fingerprint = $null
    $deniedEntries = @()
    $guardMutex = $null
    $guardLocked = $false
    try {
        try {
            $stateRoot = if ($env:MANAGED_JOBS_ROOT) { $env:MANAGED_JOBS_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.agent-customizations\managed-jobs' }
            $guardFile = Join-Path (Join-Path $stateRoot 'guard') 'denied-launches.json'
            $sha = [Security.Cryptography.SHA256]::Create()
            $fingerprint = [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($command.Trim())))
            # Test seam, part 1: announce that this process is about to enter the
            # cache transaction so a regression test can wait for every peer. While
            # the seam is active the lock wait and the hold below stretch to the
            # same bound, so the rendezvous can never outlast a legitimate waiter.
            $guardWaitMilliseconds = 2000
            if ($env:MANAGED_JOBS_GUARD_BARRIER) {
                $guardWaitMilliseconds = 30000
                $null = New-Item -ItemType File -Path "$($env:MANAGED_JOBS_GUARD_BARRIER).ready-$PID" -Force
            }
            # Serialize the read/prune/update/replace transaction across concurrent
            # hook processes: without the lock two denials read the same old state
            # and the last writer erases the other's fingerprint. The wait is short
            # and fails open — on timeout this invocation still reads the cache but
            # skips its own write rather than overwrite another writer's entry.
            $guardLockName = 'Local\managed-jobs-guard-' + [Convert]::ToHexString(
                $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($guardFile.ToLowerInvariant()))).Substring(0, 32)
            $guardMutex = [Threading.Mutex]::new($false, $guardLockName)
            try {
                $guardLocked = $guardMutex.WaitOne($guardWaitMilliseconds)
            } catch [Threading.AbandonedMutexException] {
                # The previous holder exited without releasing; ownership transferred.
                $guardLocked = $true
            }
            if (Test-Path -LiteralPath $guardFile) {
                # Ticks survive the JSON round-trip; ConvertFrom-Json mangles ISO date strings.
                $deniedEntries = @(Get-Content -LiteralPath $guardFile -Raw | ConvertFrom-Json) | Where-Object {
                    ($nowUtc.Ticks - [long]$_.deniedAtUtcTicks) -lt [TimeSpan]::FromHours(1).Ticks
                }
            }
            # Test seam, part 2: hold (bounded by the same wait) between the cache read and the
            # write until the barrier file exists. Without serialization every
            # peer completes its read here before any write, which forces the
            # lost update; with the lock only the holder reaches this point.
            if ($env:MANAGED_JOBS_GUARD_BARRIER) {
                $barrierDeadline = [datetime]::UtcNow.AddMilliseconds($guardWaitMilliseconds)
                while (-not (Test-Path -LiteralPath $env:MANAGED_JOBS_GUARD_BARRIER) -and [datetime]::UtcNow -lt $barrierDeadline) {
                    Start-Sleep -Milliseconds 20
                }
            }
        } catch {
            $guardFile = $null
            $deniedEntries = @()
        }
        $retryOfDenied = if ($fingerprint) {
            $deniedEntries | Where-Object { [string]$_.fingerprint -eq $fingerprint } | Select-Object -First 1
        } else { $null }

        if (-not $matched -and -not $backgroundRequested -and -not $retryOfDenied) { exit 0 }

        $guardTempFile = $null
        try {
            if ($guardFile -and $fingerprint -and $guardLocked) {
                $deniedEntries = @($deniedEntries | Where-Object { [string]$_.fingerprint -ne $fingerprint }) + @(
                    [ordered]@{ fingerprint = $fingerprint; deniedAtUtcTicks = $nowUtc.Ticks }
                )
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $guardFile) -Force
                $guardTempFile = "$guardFile.$PID.tmp"
                ConvertTo-Json @($deniedEntries) -Depth 4 | Set-Content -LiteralPath $guardTempFile -Encoding utf8
                # Replace in one MoveFileEx call and retry briefly: Move-Item -Force
                # deletes then moves, so concurrent hook invocations collide.
                for ($attempt = 0; ; $attempt++) {
                    try {
                        [IO.File]::Move($guardTempFile, $guardFile, $true)
                        break
                    } catch [IO.IOException], [UnauthorizedAccessException] {
                        if ($attempt -ge 5) { throw }
                        Start-Sleep -Milliseconds (10 * [math]::Pow(2, $attempt))
                    }
                }
            }
        } catch {
            if ($guardTempFile -and (Test-Path -LiteralPath $guardTempFile)) {
                Remove-Item -LiteralPath $guardTempFile -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        if ($guardMutex) {
            if ($guardLocked) { try { $guardMutex.ReleaseMutex() } catch {} }
            $guardMutex.Dispose()
        }
    }

    # Name what fired and carry the replacement, so the next call is the
    # managed job rather than another variant of the denied command.
    $trigger = if ($backgroundRequested -and $matched) {
        "run_in_background=true, and the command runs '$matched', a detached or long-running launch"
    } elseif ($backgroundRequested) {
        'run_in_background=true'
    } elseif ($matched) {
        "the command runs '$matched', a detached or long-running launch"
    } else {
        'this command was recently denied as a background or detached launch and is now a foreground rerun of it'
    }
    $controllerPath = (Join-Path $PSScriptRoot 'Invoke-ManagedJob.ps1') -replace "'", "''"
    $reason = "Denied: $trigger. Start the command as a managed job and block on it with wait, in a foreground PowerShell call without run_in_background: " +
        "`$jobs = '$controllerPath'; `$job = (& `$jobs start -Name <name> -Executable <executable> -Arguments @('<argument>') -WorkingDirectory <directory> | Out-String) | ConvertFrom-Json; " +
        "& `$jobs wait -Id `$job.id -TimeoutSeconds <seconds below the tool-call timeout>. " +
        'When wait times out the job is still running: call wait -Id <job id> again. For a shell loop or pipeline, save it as a script file and start that file as the job. ' +
        'Do not rerun the command in the foreground bounded by a tool-call timeout. ' +
        "If the user explicitly requested unmanaged execution, add the comment marker '# managed-jobs: allow-direct'."
    [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = $reason
        }
    } | ConvertTo-Json -Depth 6 -Compress
} catch {
    [ordered]@{ systemMessage = "Managed-jobs command guard failed open: $($_.Exception.Message)" } | ConvertTo-Json -Compress
}
