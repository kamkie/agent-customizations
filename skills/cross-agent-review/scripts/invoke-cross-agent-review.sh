#!/usr/bin/env bash
# Run one cross-agent review round against a committed range.
#
# Resolves and pins the review range, invokes the opposite engine's reviewer, and
# fails the round rather than reporting a review that did not happen. Emits a
# JSON result object. Judgment - triage, fixes, and the round decision - stays
# with the calling agent.
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: invoke-cross-agent-review.sh --direction <to-codex|to-claude> --focus-file <path>
                                    [--base <ref>] [--model-alias <alias>] [--effort <level>]
USAGE
    exit 2
}

direction=""
focus_file=""
base=""
model_alias="opus"
effort="medium"

while [ $# -gt 0 ]; do
    case "$1" in
        --direction) direction="${2:-}"; shift 2 ;;
        --focus-file) focus_file="${2:-}"; shift 2 ;;
        --base) base="${2:-}"; shift 2 ;;
        --model-alias) model_alias="${2:-}"; shift 2 ;;
        --effort) effort="${2:-}"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

case "$direction" in
    to-codex|to-claude) ;;
    *) echo "Direction must be to-codex or to-claude." >&2; usage ;;
esac
[ -n "$focus_file" ] || usage
[ -f "$focus_file" ] || { echo "Focus file not found: $focus_file" >&2; exit 1; }

focus="$(cat "$focus_file")"
[ -n "${focus//[[:space:]]/}" ] || { echo "The focus file is empty. State the change intent at minimum." >&2; exit 1; }

repo="$(git rev-parse --show-toplevel)" || { echo "Run from inside the target repository." >&2; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
    echo "Uncommitted changes present. Review runs on committed state; commit first." >&2
    exit 1
fi

if [ -n "$base" ]; then
    review_base="$(git rev-parse --verify "${base}^{commit}")" ||
        { echo "Cannot resolve base ref: $base" >&2; exit 1; }
else
    default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)" ||
        { echo "Cannot resolve the default branch. Pass --base explicitly instead of guessing a name." >&2; exit 1; }
    default_branch="${default_ref#origin/}"
    review_base="$(git merge-base "origin/${default_branch}" HEAD)" ||
        { echo "No merge base between origin/${default_branch} and HEAD." >&2; exit 1; }
fi

review_head="$(git rev-parse HEAD)" || { echo "Cannot resolve HEAD." >&2; exit 1; }
[ "$review_base" != "$review_head" ] || { echo "Nothing committed to review in this range." >&2; exit 1; }

assert_pr_head() {
    local number="$1" expected="$2" pr_head
    pr_head="$(gh pr view "$number" --json headRefOid --jq .headRefOid)" ||
        { echo "Cannot read the pull request head." >&2; exit 1; }
    if [ "$pr_head" != "$expected" ]; then
        echo "Pull request head is $pr_head, not the reviewed head $expected. Push the reviewed head, or rerun against the pull request's head." >&2
        exit 1
    fi
}

pull_request=0
reviewer_exit=0

if [ "$direction" = "to-codex" ]; then
    claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    companion="$(find "$claude_home/plugins" -name 'codex-companion.mjs' -type f 2>/dev/null |
        head -n 1 || true)"
    [ -n "$companion" ] ||
        { echo "Install and authenticate the codex plugin before a cross-agent review." >&2; exit 1; }

    set +e
    node "$companion" adversarial-review --wait --scope branch --base "$review_base" "$focus"
    reviewer_exit=$?
    set -e
else
    codex_home="${CODEX_HOME:-$HOME/.codex}"
    runner="$codex_home/skills/claude-runner/scripts/Invoke-ClaudeRunner.ps1"
    [ -f "$runner" ] || { echo "Install the claude-runner skill before a cross-agent review." >&2; exit 1; }

    pull_request="$(gh pr view --json number --jq .number)" ||
        { echo "Open the pull request first; the read-only reviewer mode reviews a PR, not a bare branch." >&2; exit 1; }

    # The reviewer reads the pull request's remote head, so a local HEAD check
    # alone would miss unpushed repairs or another actor's push.
    assert_pr_head "$pull_request" "$review_head"

    set +e
    pwsh -NoProfile -File "$runner" -WorkingDirectory "$repo" -ReviewPr "$pull_request" \
        -ModelAlias "$model_alias" -Effort "$effort"
    reviewer_exit=$?
    set -e

    assert_pr_head "$pull_request" "$review_head"
fi

if [ "$reviewer_exit" -ne 0 ]; then
    echo "The reviewer exited with $reviewer_exit. No review was produced; this round does not count." >&2
    exit 1
fi

current_head="$(git rev-parse HEAD)" || { echo "Cannot resolve HEAD." >&2; exit 1; }
if [ "$current_head" != "$review_head" ]; then
    echo "HEAD moved during the review. Discard this round and rerun it against the new head." >&2
    exit 1
fi

printf '{\n  "direction": "%s",\n  "repository": "%s",\n  "base": "%s",\n  "head": "%s",\n  "pullRequest": %s,\n  "reviewerExit": %s,\n  "result": "reviewed"\n}\n' \
    "$direction" "$repo" "$review_base" "$review_head" "$pull_request" "$reviewer_exit"
