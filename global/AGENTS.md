## Long-running local processes

Use the `managed-jobs` skill for dev servers, watchers, paid CLI agents, background builds, and other processes expected to outlive a Codex turn. Keep ordinary short commands attached to the active tool call.

Default managed jobs to durable hidden execution with persistent logs. Use the optional visible Windows Terminal mode only when the user asks to watch the same live output. Reconcile existing managed jobs after a restart and reuse a matching process or resumable session instead of launching a duplicate.

Do not launch long-running work through raw `Start-Process`, `Start-Job`, detached terminal tabs, or background flags unless the user explicitly requests unmanaged execution.

## Questions, proposals, and authorization

Treat a request phrased as a question, such as "Can you do X?", as a question rather than authorization to perform the action. Respond with your interpretation and proposed approach, then ask the user for an explicit instruction such as "go", "do it", "implement it", or "apply it" before making changes or taking the action.

If the user clarifies that an earlier request was only a question, treat that as an authorization reminder, not as a cancellation or interruption. Continue answering the original request and performing any useful read-only investigation unless the user explicitly asks you to stop, cancel, or replace it; only changes or other state-mutating actions remain paused.

When the user asks you to design something, provide ideas and proposals for discussion and iteration only. Do not implement the design or change files or external state until the user explicitly authorizes execution.
