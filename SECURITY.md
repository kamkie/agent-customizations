# Security policy

This repository intentionally contains reusable instructions and scripts, not
Codex runtime state.

Do not commit API keys, OAuth tokens, credentials, session transcripts,
memories, logs, managed-job records, private repository contents, or absolute
paths containing personal usernames. Run `pwsh ./scripts/verify.ps1` before
publishing changes.

If sensitive data is committed, revoke the credential first, remove it from
Git history, and then publish the rewritten history. Deleting it only in a
later commit is not sufficient.
