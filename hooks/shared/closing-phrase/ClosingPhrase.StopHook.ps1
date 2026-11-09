param([string]$ManagedHookId)

# Stop hook for Claude Code and Codex. It blocks the end of a turn once when the
# last 500 characters of the final message dictate a reply phrase or offer a
# check instead of running it; the global guidance forbids both. It reads only
# the hook's JSON input. Every other case, and every error, exits 0 without
# output, so a broken hook can never hold a session.
$ErrorActionPreference = 'Stop'

$ask = 'dictates a reply phrase. Ask the decision in plain words; a plain yes or go is the answer'
$run = 'offers a check instead of running it. Run the check now and report it, or name what only the user can provide for it'

# The whole rule set: case-insensitive regex -> what is wrong and what to do.
# Keep it short and narrow. Change it only with match counts from real endings.
$patterns = [ordered]@{
    # say "go", reply `merge 131`, say **ship it** (not: "tickets still say ...", reply "ready")
    '(?<!\b(still|can|not|they)\s)\b(say|reply)\s+(with\s+)?["''`*\p{Pi}]{1,3}(?!(ready|done)\b)[^"''`*\p{Pf}\r\n]{1,40}["''`*\p{Pf}]' = $ask
    # say go, type approve <hash>, reply merge 131, say the word (not: "when you say go")
    '(?<!\byou\s)\b(say|reply|type)\s+["''`*\p{Pi}]{0,3}(go|yes|ok|okay|approve|merge|proceed|the word)\b' = $ask
    # if you want, I can check ...
    '\bif you(.d| would)? (want|like|prefer)[^.\r\n]{0,25}\bI( can| could| will|.ll) (also )?(check|verify|investigate|inspect|look|reproduce|diagnose|confirm|dig|test|run|watch)\b' = $run
    # say if you want me to look ..., would you like me to verify ... (not: "what would you like me to inspect")
    '(?<!\bwhat\s)\b(if|do|would) you(.d| would)? (want|like) me to (check|verify|investigate|inspect|look|reproduce|diagnose|confirm|dig|test|watch)\b' = $run
    # your call on diagnosing ...
    '\byour call (on|whether)\b[^.\r\n]{0,30}\b(diagnos|investigat|check|verif|reproduc|inspect)\w*' = $run
    # I can check live if you want
    '\bI can (also )?(check|verify|investigate|inspect|look|reproduce|diagnose|confirm|dig|test|watch)\b[^.\r\n]{0,80}\bif you(.d)? (want|like|prefer)\b' = $run
}

try {
    # Read stdin as UTF-8 bytes: the console code page would garble curly quotes.
    $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false))
    $payload = ConvertFrom-Json -InputObject $reader.ReadToEnd() -NoEnumerate

    # Block at most once per stop: only a JSON object for a first Stop with an explicit false flag.
    if ($payload -isnot [Management.Automation.PSCustomObject] -or $payload.hook_event_name -isnot [string] -or
        $payload.hook_event_name -cne 'Stop' -or $payload.stop_hook_active -isnot [bool] -or $payload.stop_hook_active) { exit 0 }
    $message = $payload.last_assistant_message
    if ($message -isnot [string] -or -not $message.Trim()) { exit 0 }
    $ending = $message.Substring([Math]::Max(0, $message.Length - 500))

    foreach ($pattern in $patterns.Keys) {
        $match = [regex]::Match($ending, $pattern, 'IgnoreCase', [timespan]::FromSeconds(1))
        if (-not $match.Success) { continue }
        $found = $match.Value -replace '\s+', ' '
        [ordered]@{
            decision = 'block'
            reason = "Your ending contains '$found', which $($patterns[$pattern]). Rewrite the ending. If the text only quotes someone else's words, end the turn again unchanged."
        } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
        exit 0
    }
} catch {
    # Missing fields, bad JSON or a regex timeout must never block a stop.
}
exit 0
