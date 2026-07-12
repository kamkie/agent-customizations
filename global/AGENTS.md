## Long-running local processes

Use the `managed-jobs` skill for dev servers, watchers, paid CLI agents, background builds, and other processes expected to outlive a Codex turn. Keep ordinary short commands attached to the active tool call.

Default managed jobs to durable hidden execution with persistent logs. Use the optional visible Windows Terminal mode only when the user asks to watch the same live output. Reconcile existing managed jobs after a restart and reuse a matching process or resumable session instead of launching a duplicate.

Do not launch long-running work through raw `Start-Process`, `Start-Job`, detached terminal tabs, or background flags unless the user explicitly requests unmanaged execution.

## Questions, proposals, and authorization

Treat a request phrased as a question, such as "Can you do X?", as a question rather than authorization to perform the action. Respond with your interpretation and proposed approach, then ask the user for an explicit instruction such as "go", "do it", "implement it", or "apply it" before making changes or taking the action.

If the user clarifies that an earlier request was only a question, treat that as an authorization reminder, not as a cancellation or interruption. Continue answering the original request and performing any useful read-only investigation unless the user explicitly asks you to stop, cancel, or replace it; only changes or other state-mutating actions remain paused.

When the user asks you to design something, provide ideas and proposals for discussion and iteration only. Do not implement the design or change files or external state until the user explicitly authorizes execution.

## Pull request readiness

Treat review feedback submitted while a pull request is draft as binding. Immediately before marking any draft pull request ready, perform a thread-aware re-fetch of its current head, unresolved review threads, latest reviews, and review decision. Keep it draft while any actionable finding is untriaged, a `CHANGES_REQUESTED` review applies to the validated current head, or the head differs from the validated head.

A `CHANGES_REQUESTED` review on an earlier head does not by itself block readiness after its findings are addressed, responses are recorded, threads are resolved, and affected validation passes; it still blocks merge until cleared or replaced by current-head approval. Re-fetch immediately after the readiness transition and return the pull request to draft if new feedback, a current-head change request, or a head change raced the transition. Do not rely on an earlier flat comment read or assume draft status prevented reviewers from requesting changes.
