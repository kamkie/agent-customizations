---
name: lavish
description: Create or update rich local HTML artifacts and review them in Lavish with browser annotations, structured choices, and iterative agent feedback. Use for interactive reports, comparisons, plans, diagrams, decision documents, or visual review surfaces where a human-agent feedback loop is materially better than prose. Do not use for ordinary text responses, non-HTML deliverables, or visualizations that do not need browser review.
---

# Lavish

Use the bundled wrapper for every Lavish command. It pins the reviewed CLI
version, disables telemetry, binds only to loopback, and guards publishing,
setup, and updates.

    $lavish = Join-Path $PSScriptRoot 'scripts\Invoke-Lavish.ps1'

When $PSScriptRoot does not resolve to this skill directory, discover the
active skill directory first and construct the same script path from it.

## Build the artifact

1. Decide whether browser review materially improves the response. Keep ordinary
   answers in chat.
2. For every matching artifact type, load its focused playbook before writing:

       & $lavish playbook comparison
       & $lavish playbook plan
       & $lavish playbook input

   Available playbooks are diagram, table, comparison, plan, code, input, and
   slides. Load all that apply.
3. Write one self-contained HTML file under .lavish/ unless the user chooses
   another location. Prefer the subject project's design tokens and components;
   otherwise use deliberate local CSS. Avoid remote scripts, fonts, and assets
   unless they are necessary and their network behavior is acceptable.
4. Make the page responsive and give html or body an explicit background. Use
   native form controls for decisions. Queue a committed answer only from a
   submit button:

       window.lavish.queuePrompt('Use the selected plan', {
         tag: 'decision',
         queueKey: 'plan',
         element: event.currentTarget,
         data: { answer: selectedPlan }
       });

## Run the review loop

Open the artifact:

    & $lavish .\.lavish\artifact.html

Then keep the poll attached to the active turn:

    & $lavish poll .\.lavish\artifact.html --agent-reply 'What to review first'

- Do not detach, background, or impose a normal-use timeout on the poll.
- Apply submitted annotations and decisions, save the same HTML file, reply
  through --agent-reply, and poll again.
- Treat browser layout findings as work only after the user queues them.
- When the user ends the session, stop polling and do not reopen it without a
  new request.
- Stop the local server after the review finishes:

      & $lavish stop

## Protected operations

- Keep the default loopback binding. Do not expose Lavish on a LAN, tailnet,
  public interface, or unauthenticated reverse proxy.
- Do not run share. It uploads the artifact to a third-party service and is
  public by default. Only after an explicit publishing request, state the
  destination and visibility, then use -AllowPublish.
- Do not run setup. It changes agent or editor configuration. Use -AllowSetup
  only for the exact setup action the user authorized.
- Do not run update. Change the pinned version in the reviewed wrapper through
  a repository change after checking upstream release notes and security
  advisories. -AllowUpdate is reserved for an explicit exceptional request.
- Never put secrets, credentials, private keys, or sensitive local content in an
  artifact. Review remote references before exporting or publishing.
