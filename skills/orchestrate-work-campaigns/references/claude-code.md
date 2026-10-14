# Claude Code Rules

Read this when the controller runs in Claude Code. Everything else in the skill still applies.

- **Owner task:** a separate session the user can open, started in its own git worktree. A subagent is never an owner task; use one only to gather read-only context.
- **Skill invocation:** where the skill says `Use $skill-name`, start the prompt with `/skill-name`.
- **Messaging:** address sessions by session ID. Put the controller's session ID in every worker contract, and tell the worker to send contract deltas and its handoff to it as a cross-session message.
- **Opposite-agent review:** Codex, through `cross-agent-review`.

## Standing coordinator

When the user makes this session the coordinator without a tracker campaign, skip the matrix, pilot, and denominator, and keep the controller boundary:

- Do no workstream work here: no edits, builds, logins, or remote checks. Send work to the session that owns it, small read-only checks to a subagent, and anything bigger to a new session. Route a delivery campaign through the common path.
- Move, pin, retitle, and file sessions without asking. Ask only before archiving, deleting, or stopping one.
- A session's report is a claim. Verify it before you tell the user the work is done.
- A question about sessions gets an answer and does not start the role.
