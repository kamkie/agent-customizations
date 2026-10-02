# Claude Microsoft 365 MCP customization

Use these bindings with Claude Code's Microsoft 365 (Graph) MCP connector.
Check current tool schemas and returned metadata for limits and paging.
Do not apply Codex Teams app parameters to these tools. The
[shared entrypoint](../SKILL.md) owns authorization and reporting boundaries.

## Tools and limits

| Tool | Page size and paging | Use it for |
| --- | --- | --- |
| `read_resource` on `teams:///chats/{chatId}/messages` | 50 messages, no cursor | Recent chat history; default first call |
| `read_resource` on `.../messages/{messageId}` | 1 message | Full HTML body, attachment names and links, reactions, edit time |
| `chat_message_search` | 25 per page; `offset` from `nextOffset`, max 1000; `totalResultCount` when known | Older history and cross-chat keywords |
| `teams_list_chats` | 25 per page; `cursor` from `nextCursor` | Chat ID by members or topic |
| `teams_list_channel_messages` | Up to 50; `cursor` from `nextCursor` | Channel posts or replies with `parentMessageId` |
| `teams_list_teams`, `teams_list_channels` | No paging observed | Team and channel IDs |

Use returned per-message URIs for full bodies. Previews stop at about 300
characters and search summaries are shorter. Inline images (`hostedContents`)
cannot be viewed on this observed surface; use the shared permitted fallbacks
without interrupting the user before reporting images as unseen.
For a linked meeting chat, a `chatRenamed` system event can give its title.

## Recent-read completeness

The chat resource returns the 50 most recently **updated** messages. Reactions
and edits can pull an old message in and push newer sent messages out. Read
the trailing `truncated` note: it means older messages exist.

When truncated, a period is complete only for messages created strictly after
the oldest `lastModifiedDateTime` returned, provided that timestamp is present
for every returned message: an unreturned message was last updated, and thus
created, no later than that boundary. The oldest `createdDateTime` is not a
completeness boundary. If modification timestamps are missing, treat no period
as complete. Keep searched periods separately labeled in the final coverage.

## Older chat history

`chat_message_search` cannot filter by chat. Narrow by people and time, then
keep only results whose `chatUri` equals the target chat's
`teams:///chats/<encoded-id>/messages`.

- Use query `*` with `sender` and a narrow date window (`afterDateTime` and
  `beforeDateTime`, a few days), once per participant. Wide windows with only
  `sender` silently skipped whole days in testing.
- `sender` plus `recipient` targets chats both people are in. A person's sent
  messages never list that person as recipient; channel posts have no
  recipients. Participant-limited searches can miss departed participants or
  system events; report that limitation.
- Avoid `*` with only a date window: it returns every chat and channel,
  including alert cards. Avoid long `OR` keyword lists; use specific terms
  with people filters when a keyword is the actual question.
- Pages can contain fewer than 25 items. Follow `nextOffset` while
  `moreResults` indicates more results; a short page is not an end marker.
  If the offset cap blocks continuation, narrow the window and report any
  residual gap. Do not invent an offset beyond the supported limit.
- A prefix like "searched N of M chats" indicates the slow per-chat scan
  fallback observed when `ChannelMessage.Read.All` was missing. Coverage is
  partial and 429s are likely; stop and report the limited coverage.

Work backwards window by window from the recent-read completeness boundary,
or from now if none was established. Apply the shared deduplication and stop
rules. A creation event or a returned chat `createdDateTime` can establish
the chat's start; an empty search window cannot.

## Channels

Resolve `teamId` with `teams_list_teams` and `channelId` with
`teams_list_channels`, or use IDs decoded from a returned `channelUri`.
`teams_list_channel_messages` returns posts ordered by last activity. Pass
`parentMessageId` to read a post's replies and page using the returned cursor,
keeping other parameters unchanged. Reading posts alone does not cover replies.

## Write bindings

Discover the connector's send, reply, or create-chat action and inspect its
schema for the exact target IDs and text parameters. Do not substitute Codex
action names. Apply the shared explicit request and target/text confirmation
boundary before any write, and report unavailable actions as unavailable.

## Waiting after throttling

The observed 429 response supplies `retryAfterSeconds` (62 seconds in one
case). Wait at least the returned interval. Where foreground sleeps are blocked
and `Monitor` is available, use it with a bounded `until` loop that reports
completion once. That wait only serves the cooldown; it must not call Graph.
If this runtime lacks a supported waiting mechanism or a retry interval, report
the cooldown limitation. Apply the shared one-retry stopping rule.
