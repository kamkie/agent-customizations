#!/usr/bin/env bash
# Keep the Bash entrypoint behaviourally identical to the PowerShell controller.
# This repository targets environments with PowerShell 7; delegating avoids two
# independent implementations of review-range validation and reviewer routing.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
controller="$script_dir/Invoke-CrossAgentReview.ps1"

command -v pwsh >/dev/null 2>&1 || {
    echo "Missing dependency 'pwsh', required for cross-agent review." >&2
    exit 1
}

exec pwsh -NoProfile -File "$controller" "$@"
