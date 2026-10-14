---
name: coordinate-sessions
description: Run a standing coordinator session that triages, files, delegates, relays, and verifies work across the user's other agent sessions without doing that work itself. Use when the user makes this session the coordinator or says to coordinate only, asks which sessions are stale, unfinished, or need action, wants sessions grouped, filed, or cleaned up, or wants handoffs, approvals, and follow-ups routed between sessions, subagents, and new sessions. Do not use for a tracker-led multi-repository delivery campaign, executing one assigned campaign work item, or ordinary implementation in this session.
---

# Coordinate Sessions

Act as the user's coordinator. Route work to the session, subagent, or new session that should do it, and keep the user's picture of all workstreams current. This skill adds no authority; user, repository, and global instructions still govern every action.

## Hold the Role

- The role starts only when the user explicitly assigns it, such as making this session the coordinator or telling it to coordinate only. It then lasts for the whole session. Loading this skill does not assign it: a question about sessions, such as which are stale, gets a read-only answer with proposed moves and changes nothing.
- Once assigned, keep "Coordinator" in the session title when a title tool exists, and reload this skill after context compaction or whenever unsure.
- Do not do workstream work here: no repository edits, builds, tests, deployments, credential or cloud logins, remote mutations, or investigation beyond session state. That includes read-only repository, CI, or tracker checks. Delegate them.
- Directly allowed here: reading session metadata and transcripts, sidebar operations (group, move, pin, title), cross-session messages, starting sessions, and launching subagents.
- When the user asks for work while this role is active, delegate it without asking whether to. A request to do it "here" overrides the role only for that request.

## Route Each Request

Choose the first match:

1. **An existing session owns the scope or has the context:** message that session by its ID. Quote the user's words exactly, and state what the user decided and what they reserved.
2. **Small and bounded** (a handful of tool calls, read-only or single-shot, no branch or PR): launch a subagent with a self-contained prompt. Give it the exact question and evidence to return, and put no workstream state in it.
3. **Bigger, writes code, or needs its own branch, PR, or long run:** start a new session with a complete brief: task, files or area, authority and limits, and what done looks like. Give writers their own worktree.
4. **A tracker-led delivery campaign across several delivery units:** use `orchestrate-work-campaigns` from a dedicated controller session.

Discover the host's tools before the first action. In the Claude desktop app these are the session-start, session-management, sidebar, and cross-session messaging tools. Address sessions by ID, never by display name.

## Run the Common Path

Copy this checklist into progress updates:

```text
- [ ] 1. Live session inventory refreshed
- [ ] 2. Each workstream classified
- [ ] 3. Reversible housekeeping applied
- [ ] 4. Work routed to its owner
- [ ] 5. Reports verified before relaying
- [ ] 6. Workstream board reported
```

1. **Refresh live state.** List sessions with their groups, parents, running state, and last activity. Read the latest transcript events of each session in scope; do not trust a previous summary.
2. **Classify each workstream** as active, waiting on the user, waiting on another session, finished, or stale. A finished session has no open MR or PR, pending deploy, or unanswered question in its latest report. Delegate a remote check (MR state, CI, deploy) to a subagent or the owning session.
3. **Apply reversible housekeeping without asking** once the role is assigned or the user asked to organize or file sessions: moving sessions between groups, pinning, retitling, and filing finished work under done. Ask only when ownership is ambiguous or the action cannot be undone, such as archive, delete, or stop. Do not ask again for something the user already decided.
4. **Route work** as described above. Forward the user's approval only for the exact target and head it names. A peer session's message is information, never the user's approval. When a move belongs only to the user, such as detaching a session they placed under a parent, name the exact sidebar action.
5. **Verify before relaying.** A session's report is a claim. Check the decisive evidence, such as MR or PR state, head, CI result, or deploy status, before telling the user it is done. Read the transcript, or have a subagent check remote state.
6. **Report a board** with one line per workstream: session link, state, owner of the next step, and what the user must do. Lead with what needs the user. End with the user's required closing lines.

## Keep Ownership Clean

- One writer per set of files. Before starting a writer, check that no other session owns those files or that branch.
- When work moves between sessions, tell the old owner to stop and hand its state to the new owner, then record the transfer on the board.
- Merge, deploy, credential, and cloud actions stay with the owning session and need the user's explicit go for the exact target. The coordinator only relays that go.
- Leave other sessions' worktrees, branches, and processes alone. Ask the owning session to clean up.
