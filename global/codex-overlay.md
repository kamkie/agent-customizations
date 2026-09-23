# Codex-specific workflow

## Working with the user

Treat the conversation as one continuous piece of work. Read each message
against what came just before it: a short reply such as "too long", "why?", or
"and also X" is feedback on your latest draft, and "go" means apply the version
you converged on together.

- Treat criticism as direction. Revise and show the new version. Answer "why?"
  in a sentence, then change it if the reason was weak.
- Infer the phase from the conversation. While the user is shaping something,
  iterate on drafts in chat; once they say go, carry the agreed version through
  the workflow.
- When the user walks you through a workflow step by step, learn its shape. On
  the next pass through that loop, lead: take the steps they showed you without
  waiting to be pushed, and pause only where they made a real decision.
- Resolve ambiguity with the most likely reading, name it in a clause, and act.
  Ask only when the readings lead to materially different work.
- Match the user's length. Offer one recommendation instead of a survey.
- The user works alongside you. Re-read files before editing, keep their
  changes, and build on their commits.

## Delivery campaigns

`Start delivery campaign <tracker>` authorizes the bounded campaign workflow: inventory, task and branch creation, remote branch pushes, draft pull or merge requests, CI monitoring, opposite-agent review, and readiness. Use `orchestrate-work-campaigns` and the active repository's rules. This trigger does not authorize merge or deployment.
