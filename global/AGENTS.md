## Long-running local processes

Use the `managed-jobs` skill for dev servers, watchers, paid CLI agents, background builds, and other processes expected to outlive a Codex turn. Keep ordinary short commands attached to the active tool call.

Default managed jobs to durable hidden execution with persistent logs. Use the optional visible Windows Terminal mode only when the user asks to watch the same live output. Reconcile existing managed jobs after a restart and reuse a matching process or resumable session instead of launching a duplicate.

Do not launch long-running work through raw `Start-Process`, `Start-Job`, detached terminal tabs, or background flags unless the user explicitly requests unmanaged execution.

## Questions, proposals, and authorization

Treat a request phrased as a question, such as "Can you do X?", as a question rather than authorization to perform the action. Respond with your interpretation and proposed approach, then ask the user for an explicit instruction such as "go", "do it", "implement it", or "apply it" before making changes or taking the action.

When a proposal or read-only investigation ends at an authorization checkpoint, lead the final response with `Action required:`. State the exact decision needed and provide a concise, copyable instruction that authorizes the proposed next actions. Do not make the user infer the next step from the closing summary.

If the user clarifies that an earlier request was only a question, treat that as an authorization reminder, not as a cancellation or interruption. Continue answering the original request and performing any useful read-only investigation unless the user explicitly asks you to stop, cancel, or replace it; only changes or other state-mutating actions remain paused.

When the user asks you to design something, provide ideas and proposals for discussion and iteration only. Do not implement the design or change files or external state until the user explicitly authorizes execution.

## Scope discipline

Implement exactly what the user requested using the smallest coherent diff.

- Change only code required for the requested behavior.
- Do not add legacy support, compatibility shims, fallbacks, aliases, migrations, feature flags, speculative abstractions, adjacent fixes, cleanup, or unrelated refactors unless explicitly requested.
- When existing behavior is wrong, replace or delete it. Do not preserve both old and new behavior for existing callers or outdated tests.
- Update only directly affected tests and run the narrowest relevant checks.
- Do not add tests that merely assert removed source text, commands, configuration fragments, dependencies, or other implementation details remain absent. Deleting the obsolete implementation is sufficient. Test current observable behavior or a concrete safety invariant; otherwise leave the tests unchanged.
- Before finishing, inspect the diff and revert every change not required by the request.
- Do not silently expand scope. Report genuinely necessary extra work instead.

## Pull request readiness

Before marking a pull request ready, re-fetch its head and review threads. Keep it draft if the head changed, a finding is untriaged, or `CHANGES_REQUESTED` applies to the current head; re-fetch after the transition and revert to draft if this gate changed. Resolved feedback on an earlier head does not block readiness, but its review blocks merge until current-head approval.
