# Codex Teams app customization

Use these bindings with the connected Teams app in Codex. Tool names below
are action suffixes; discover their full names and current schemas.
Do not apply the Claude connector's 50-message resource cap or search offsets.
The [shared entrypoint](../SKILL.md) owns authorization and reporting boundaries.

## Tool bindings

| Task | Action and parameters |
| --- | --- |
| Read a link or full message | `fetch(path)` with the exact returned path or user's Teams URL |
| Resolve a named conversation | `resolve_chat(participant_names, topic)` with known filters |
| Read chat history | `list_chat_messages(chat_id, sent_after, top)` |
| Resolve a channel | `resolve_channel(channel_name, team_id or team_name)` |
| Read channel posts and replies | `list_channel_messages(team_id, channel_id, include_replies, sent_after, top)` |
| Search | `search(query, chat_id, team_id, channel_id, sent_after, topn)` with known container filters |

Only supply optional parameters needed for the request. `sent_after` is an
ISO 8601 lower bound on sent time. `top` is the maximum returned after automatic
pagination, not a page cursor. These list actions expose no cursor parameter;
never invent one. Search also accepts sender/recipient names and
`include_channel_threads`; inspect its schema for the exact filter form.

## History and channels

- `fetch` of a chat link expands recent messages; it does not promise the
  complete chat. Prefer `list_chat_messages` with the known chat ID for a
  requested period, using `sent_after` and a suitable `top`.
- If a response reaches the requested cap or reports truncation, completeness
  is unproven. Increase `top` only within the current schema/service limits
  when useful. If the connector cannot expose the remainder, report the gap;
  do not treat automatic pagination as a guarantee of unlimited history.
- For keyword questions, scope `search` to the known `chat_id`, or to
  `team_id`/`channel_id`, and fetch relevant hits using their canonical `path`.
  The filters narrow search results; they do not turn search into a transcript.
- Resolve a named channel in its known team, then call
  `list_channel_messages` with `include_replies=true` when thread content is
  relevant. Inspect the result for reply truncation as well as post limits.
  Fetch returned message paths when fuller content is needed; report any
  replies the available actions cannot expose.

## Write bindings

After the shared explicit-request and exact-target/text confirmation steps,
use `send_chat_message`, `send_channel_message`, `reply_to_message`, or
`reply_to_channel_message` as appropriate. Inspect the selected action's schema
for required IDs and body format. Use `validate_write_target` before writes
when a destination is ambiguous or expressed in natural language, then resolve
any remaining ambiguity before showing the final target. Use `create_chat`
only for an explicitly requested new chat; an existing chat does not need
recreation. Never infer send authority from a summary request.

## Waiting after throttling

Use the supported Codex clock/sleep tool when available, splitting waits into
intervals allowed by the tool and checking the full retry interval has elapsed.
New user input can end a sleep early; honor steering and wait any remaining
cooldown before another Graph call. Do not call Claude's `Monitor`. If the
service provides no retry interval, report the throttle without guessing a
connector-specific delay. Apply the shared one-retry stopping rule.
