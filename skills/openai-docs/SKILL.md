---
name: openai-docs
description: Verify OpenAI product, model, API, SDK and Codex behavior using the evidence that owns the question. Use local configuration/session evidence for local setup, instruction or tool troubleshooting; use current official documentation for product facts, models, pricing, limits and API guidance. Do not route unrelated repository implementation or generic software tasks here merely because they mention an agent.
---

# OpenAI Docs

Answer the requested OpenAI/Codex question with current, attributable evidence.
This read-only workflow adds no authority to change configuration, consume
credits, install tools, publish or contact support.

## Choose the evidence source

- **Local state:** inspect the exact configured source, effective settings,
  relevant native session metadata/logs or installed tool code first. Examples
  include whether a prompt override loaded, which child permission mode ran,
  or which instruction caused an observed behavior. Distinguish file contents,
  runtime loading and demonstrated behavior. Do not browse merely to verify a
  fact directly established by the local runtime.
- **External product facts:** use official documentation for capabilities,
  settings semantics, model availability, pricing, limits, API/SDK guidance,
  model selection and migrations. Local configuration does not prove a public
  product claim or account entitlement.
- **Mixed question:** establish local observations, then verify only the
  unresolved external claims. Preserve the user's named model and execution
  surface rather than substituting a newer model or a different client.

## Run the documentation path

1. Discover available official documentation search and page-fetch tools. Search
   the exact topic with a concise query, then fetch the matching page. Otherwise
   use web search restricted to `developers.openai.com`, `platform.openai.com`
   and `learn.chatgpt.com`, and open the underlying result. Prefer
   `learn.chatgpt.com` for ChatGPT Work.
2. Read the section that answers the question. Search another official source
   only when it leaves a material gap. Do not load a whole prompt manual or
   unrelated migration guide for a simple configuration fact.
3. For technical work, identify the exact API/SDK/version and execution surface.
   Follow its current official examples and preserve relevant parameter and
   permission distinctions. Resolve an unspecified current model before
   proposing a migration; retain the user's explicit target when specified.
4. Cite the page supporting each external claim. Label an inference, stale
   source, unavailable price/account fact or unresolved behavior precisely.
   Never use a snippet or a plausible model name as proof. Say "OpenAI Docs"
   or "official OpenAI documentation" in user-facing references.

## Complete the task

For diagnosis, distinguish the observed failing operation from hypotheses and
use a discriminating check. Reuse available records; do not ask the user to
confirm local facts you can inspect. A tool denial remains a denial even if
local configuration says Full access. Continue independent permitted work.

For an authorized implementation, apply the verified guidance and carry the
original task through its required result; documentation retrieval is a
checkpoint. Use an available API-key provisioning workflow only when actually
building/running an API-backed client, not for conceptual or read-only guidance.
Keep secrets out of prompts and artifacts. No configuration mutation is implied
by this skill; apply the task's existing authority and deployment boundary.
