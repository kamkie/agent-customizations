---
name: teams-graph-connector
description: Read Microsoft Teams chats and messages through the Microsoft 365 (Graph) MCP connector without tripping Graph rate limits. Use when asked to check, summarize, or catch up on a Teams chat, a Teams chat link, a conversation with a named person, or a group chat. Do not use for Outlook mail, calendar, SharePoint, or sending Teams messages.
---

# Teams via the Microsoft Graph connector

The Teams tools call Microsoft Graph on the user's behalf. Graph throttles
Teams chat endpoints per app per tenant and returns `429 TooManyRequests`
with `retryAfterSeconds` (observed: 62 s). The budget is shared with every
other Claude session on the same connector, so one expensive call can block
the next several minutes of work.

## Call cost (observed)

| Tool | Graph calls | Use it for |
|------|-------------|------------|
| `read_resource` on `teams:///chats/{chatId}/messages` | 1 | Whole recent conversation, both sides, newest first. **Default choice.** |
| `read_resource` on `teams:///chats/{chatId}/messages/{messageId}` | 1 | Full HTML body of one message when the preview is truncated. |
| `teams_list_chats` | 1 per page of 25 | Finding a chat ID by member name or topic. |
| `chat_message_search` without date filters | 1 (Graph Search) | Cross-chat keyword search, only if `ChannelMessage.Read.All` is granted; otherwise it silently falls back to the scan below. |
| `chat_message_search` with `afterDateTime`/`beforeDateTime` or `sender` | up to ~50 (one per chat scanned) | Avoid. It scans up to 50 chats and reliably triggers 429. |

## Workflow

1. **Derive the chat ID from the link when one is given.** A Teams chat URL
   `https://teams.microsoft.com/l/chat/<id>/conversations?...` carries the ID
   verbatim. One-on-one IDs look like `19:<guid>_<guid>@unq.gbl.spaces`, group
   and meeting chats like `19:<hex>@thread.v2` or `19:meeting_<base64>@thread.v2`.
   Skip `teams_list_chats` entirely in that case.
2. **Read the chat in one call.** URL-encode `:` as `%3A` and `@` as `%40`
   in the ID and call `read_resource` with
   `teams:///chats/<encoded-id>/messages`. The result contains sender,
   timestamp, and `bodyPreview` for each message, both participants, newest
   first. This is almost always enough to summarize.
3. **Fetch single messages only when needed.** Use the per-message URI from
   step 2 when a preview is cut off or you need attachments or mentions.
4. **Find a chat without a link** with one `teams_list_chats` page, matching on
   member display names or topic. Page further only if the chat is not in
   the first 25.
5. **Search across chats** only without date filters and only when a keyword
   is the real question. Note the result prefix: a "searched N of M chats"
   line means the scan fallback ran and coverage is partial.

## On 429

- Do not retry immediately and do not fire other Graph calls in parallel.
  Wait at least `retryAfterSeconds` (round up to ~65 s). Foreground sleeps
  are blocked; use a `Monitor` with a bounded `until` loop that echoes once.
- After the wait, spend the budget on the cheapest call that answers the
  question. One `read_resource` on the chat messages URI is safer than any
  search.
- If a second 429 follows, report what was read and what is missing instead
  of looping. Another session may be consuming the same budget.

## Reporting

- Quote who said what with timestamps; mark edits (`lastEditedDateTime`) and
  system events (pinned, members added) as such.
- Summaries stay internal: chat content is sensitive personal or business
  data and must not be copied into tracked repository files.
