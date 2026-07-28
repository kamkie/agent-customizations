#!/usr/bin/env bash
# Run one cross-agent review round against a committed range.
#
# Resolves and pins the review range, invokes the opposite engine's reviewer, and
# fails the round rather than reporting a review that did not happen.
#
# The reviewer's own output goes to stderr; stdout carries exactly one JSON
# object describing the round, so a caller can parse the range that was actually
# reviewed. Judgment - triage, fixes, and the round decision - stays with the
# calling agent.
#
# Exit codes: 0 reviewed, 1 round failed, 2 invalid invocation.
#
# Kept behaviourally equivalent to Invoke-CrossAgentReview.ps1: same guard order,
# same exit statuses, same JSON shape. The one deliberate difference is that this
# implementation must locate pwsh for --direction to-claude, because the runner
# it delegates to is a PowerShell script.
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: invoke-cross-agent-review.sh --direction <to-codex|to-claude> --focus-file <path>
                                    [--base <ref>] [--model-alias <alias>] [--effort <level>]
USAGE
}

invalid() { echo "$1" >&2; usage; exit 2; }
failed() { echo "$1" >&2; exit 1; }

require_value() {
    # $1 option name, $2 remaining arg count. Validate arity before shifting, so
    # a missing value reports usage instead of tripping set -e inside shift.
    [ "$2" -ge 2 ] || invalid "Option $1 requires a value."
}

assert_dependency() {
    command -v "$1" >/dev/null 2>&1 || failed "Missing dependency '$1', required for $2."
}

json_escape() {
    # Escapes every character JSON forbids raw, not just the common ones:
    # unescaped C0 controls are legal in Unix paths and make stdout unparseable.
    local s="$1" out="" i c code len
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    len=${#s}
    for (( i = 0; i < len; i++ )); do
        c="${s:i:1}"
        case "$c" in
            $'\b') out+='\b' ;;
            $'\f') out+='\f' ;;
            $'\n') out+='\n' ;;
            $'\r') out+='\r' ;;
            $'\t') out+='\t' ;;
            *)
                printf -v code '%d' "'$c"
                if [ "$code" -lt 32 ] && [ "$code" -ge 0 ]; then
                    printf -v out '%s\\u%04x' "$out" "$code"
                else
                    out+="$c"
                fi
                ;;
        esac
    done
    printf '%s' "$out"
}

direction=""
focus_file=""
base=""
model_alias="opus"
effort="medium"

while [ $# -gt 0 ]; do
    case "$1" in
        --direction) require_value "$1" $#; direction="$2"; shift 2 ;;
        --focus-file) require_value "$1" $#; focus_file="$2"; shift 2 ;;
        --base) require_value "$1" $#; base="$2"; shift 2 ;;
        --model-alias) require_value "$1" $#; model_alias="$2"; shift 2 ;;
        --effort) require_value "$1" $#; effort="$2"; shift 2 ;;
        -h|--help) usage; exit 2 ;;
        *) invalid "Unknown argument: $1" ;;
    esac
done

# --- invocation validation (exit 2), matching Invoke-CrossAgentReview.ps1 ----
direction="$(printf '%s' "$direction" | tr '[:upper:]' '[:lower:]')"
case "$direction" in
    to-codex|to-claude) ;;
    *) invalid "Direction must be to-codex or to-claude." ;;
esac
[ -n "$focus_file" ] || invalid "A focus file is required."
[ -f "$focus_file" ] || invalid "Focus file not found: $focus_file"
focus="$(cat "$focus_file")"
[ -n "${focus//[[:space:]]/}" ] || invalid "The focus file is empty. State the change intent at minimum."

# --- preflight, in the same order as the PowerShell implementation ----------
assert_dependency git "range resolution"
if [ "$direction" = "to-codex" ]; then
    assert_dependency node "the Codex plugin runtime"
else
    assert_dependency gh "pull-request head verification"
    assert_dependency pwsh "the claude-runner script"
fi

repo="$(git rev-parse --show-toplevel)" ||
    failed "Not inside a Git repository. Run from the target repository."

# Capture status separately and check its exit status. Inside an if-condition
# command substitution, set -e does not propagate a failure, so a corrupt index
# would otherwise read as a clean tree.
tree_status="$(git status --porcelain)" ||
    failed "Cannot read the working tree state; refusing to assume it is clean."
[ -z "$tree_status" ] ||
    failed "Uncommitted changes present. Review runs on committed state; commit first."

if [ -n "$base" ]; then
    review_base="$(git rev-parse --verify "${base}^{commit}")" || failed "Cannot resolve base ref: $base"
else
    default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)" ||
        failed "Cannot resolve the default branch. Pass --base explicitly instead of guessing a name."
    default_branch="${default_ref#origin/}"
    review_base="$(git merge-base "origin/${default_branch}" HEAD)" ||
        failed "No merge base between origin/${default_branch} and HEAD."
fi

review_head="$(git rev-parse HEAD)" || failed "Cannot resolve HEAD."
[ "$review_base" != "$review_head" ] || failed "Nothing committed to review in this range."

assert_pr_head() {
    local number="$1" expected="$2" pr_head
    pr_head="$(gh pr view "$number" --json headRefOid --jq .headRefOid)" ||
        failed "Cannot read the pull request head."
    [ "$pr_head" = "$expected" ] ||
        failed "Pull request head is $pr_head, not the reviewed head $expected. Push the reviewed head, or rerun against the pull request's head."
}

pull_request=0
reviewer_exit=0

if [ "$direction" = "to-codex" ]; then
    # Resolve the plugin through the authoritative installed-plugin manifest.
    # Selecting by file mtime or first find hit could execute a stale
    # marketplace copy instead of the installed one - a local-code trust
    # boundary, not a convenience.
    claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    manifest="$claude_home/plugins/installed_plugins.json"
    [ -f "$manifest" ] || failed "No installed-plugin manifest at $manifest. Install the codex plugin first."

    companion="$(node -e '
        const fs = require("fs");
        const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const e = (m.plugins || {})["codex@openai-codex"];
        if (!e || e.length === 0) { console.error("The codex@openai-codex plugin is not installed."); process.exit(1); }
        if (e.length !== 1) { console.error("Ambiguous codex@openai-codex installation; resolve it before reviewing."); process.exit(1); }
        process.stdout.write(require("path").join(e[0].installPath, "scripts", "codex-companion.mjs"));
    ' "$manifest")" || failed "Cannot resolve the installed codex plugin."
    [ -f "$companion" ] || failed "The installed codex plugin has no reviewer script at $companion."

    set +e
    node "$companion" adversarial-review --wait --scope branch --base "$review_base" "$focus" 1>&2
    reviewer_exit=$?
    set -e
else
    codex_home="${CODEX_HOME:-$HOME/.codex}"
    runner="$codex_home/skills/claude-runner/scripts/Invoke-ClaudeRunner.ps1"
    [ -f "$runner" ] || failed "Install the claude-runner skill before a cross-agent review."

    pull_request="$(gh pr view --json number --jq .number)" ||
        failed "Open the pull request first; the read-only reviewer mode reviews a PR, not a bare branch."

    # The reviewer reads the pull request's remote head, so a local HEAD check
    # alone would miss unpushed repairs or another actor's push.
    assert_pr_head "$pull_request" "$review_head"

    set +e
    pwsh -NoProfile -File "$runner" -WorkingDirectory "$repo" -ReviewPr "$pull_request" \
        -ModelAlias "$model_alias" -Effort "$effort" 1>&2
    reviewer_exit=$?
    set -e
fi

# Check the reviewer's status before any other command runs: a later failure
# would otherwise report the wrong cause and hide a timeout, crash, or auth
# failure.
[ "$reviewer_exit" -eq 0 ] ||
    failed "The reviewer exited with $reviewer_exit. No review was produced; this round does not count."

[ "$direction" != "to-claude" ] || assert_pr_head "$pull_request" "$review_head"

current_head="$(git rev-parse HEAD)" || failed "Cannot resolve HEAD."
[ "$current_head" = "$review_head" ] ||
    failed "HEAD moved during the review. Discard this round and rerun it against the new head."

printf '{\n  "direction": "%s",\n  "repository": "%s",\n  "base": "%s",\n  "head": "%s",\n  "pullRequest": %s,\n  "reviewerExit": %s,\n  "result": "reviewed"\n}\n' \
    "$(json_escape "$direction")" "$(json_escape "$repo")" "$(json_escape "$review_base")" \
    "$(json_escape "$review_head")" "$pull_request" "$reviewer_exit"
