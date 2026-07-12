# Maintaining agent instructions and skills

Use this guide when changing reviewed agent instructions, an existing skill, or
the references and tooling that support them. It complements the
[customization ownership and skill-admission policy](customization-ownership.md),
which remains authoritative for deciding where a rule belongs.

## Establish the maintenance boundary

1. Edit the reviewed sources in this repository, not files in a live agent
   home. Deployment is a separate, explicitly authorized activation step.
2. Read the complete canonical instruction or `SKILL.md`, every reference
   required by the changed behavior, and the relevant target mapping in
   `config/manifest.json` before editing.
3. Classify each new or changed rule by ownership. Keep stable personal defaults
   in global guidance, repeated portable workflows in skills, and repository
   contracts in the repository that owns them.
4. Preserve precedence. A skill may discover and obey higher-precedence policy,
   but it must not copy repository actors, commands, merge gates, or other
   target-specific contracts into a reusable workflow.
5. Keep runtime state and private material out of reviewed sources. Do not
   import sessions, logs, records, credentials, machine paths, or generated
   configuration as durable instructions.

## Maintain agent instructions

- Keep a rule only when it is stable, broadly applicable at that instruction
  scope, and likely to change agent behavior materially.
- Write direct, testable instructions. State the trigger, required behavior,
  important boundary, and expected evidence when those are not obvious.
- Replace obsolete behavior instead of preserving contradictory old and new
  rules. Remove duplicated copies whose independent maintenance could drift.
- When another source owns a mutable detail, link to or discover that source at
  runtime. Repeat only a short safety boundary that readers need at both routing
  points, and identify the canonical owner.
- Keep target-specific behavior in the target's instruction file. Change both
  Codex and Claude guidance only when the behavior is intentionally shared and
  valid for both agents.

## Maintain skill entrypoints and references

Treat `SKILL.md` as both the routing surface and the executable entrypoint for
the normal workflow.

The entrypoint must contain enough information to complete the common path
without opening a reference:

- a bounded frontmatter description with positive and important negative
  triggers;
- controller, script, or resource discovery and required setup;
- one complete normal invocation or action sequence with every variable defined
  and every user-supplied placeholder explicit;
- non-negotiable authorization, safety, secret-handling, and process-lifecycle
  rules needed on a normal run; and
- the normal completion, evidence, or handoff expectation.

Move uncommon variants, advanced configuration, specialized recovery,
troubleshooting, long examples, and detailed rationale into `references/`.
Link each reference at the decision point that requires it. Do not require a
reference merely to finish setup or construct the common invocation.

Compactness is an outcome, not a line-count target. Remove repetition and
low-value prose, but do not shorten an entrypoint until its examples depend on
undefined variables, hidden setup, or mandatory reference loading. Keep each
reference focused enough that an agent can load the needed branch without
loading unrelated material.

When behavior changes, update the entrypoint, directly affected references,
scripts, and deterministic tests together. Change the manifest or deployment
tooling only when target mapping or installation behavior actually changes.

## Validate progressive disclosure

Use realistic forward tests in addition to structural checks.

1. Give a fresh agent the skill entrypoint and a representative common-path
   task while making references unavailable. It must identify the workflow,
   construct a complete invocation, preserve the required guardrails, and stop
   before any unauthorized or paid action.
2. Give a fresh agent one advanced scenario. It should follow the entrypoint's
   link to the directly relevant reference and should not need unrelated
   references.
3. Test every executable example for defined variables, explicit placeholders,
   correct path resolution, and valid parameters. Prefer deterministic mocks or
   dry runs over paid or state-mutating validation.
4. Review the diff for publication hazards, ownership drift, stale links,
   duplicated mutable rules, and details that belong to runtime state.

Record what each forward test could and could not prove. A test that opened a
reference does not prove that the entrypoint is self-contained.

## Validate and deliver

- Run `pwsh ./scripts/verify.ps1` and `git diff --check` for every change.
- Run `pwsh ./scripts/test.ps1` after changing installation, status,
  verification, manifest, or other deployment tooling.
- Use `pwsh ./scripts/status.ps1` when reviewed-versus-live drift is relevant.
  Drift is evidence to report, not permission to install.
- Inspect the final diff and remove unrelated changes before committing.
- Follow the repository's branch, pull-request, cross-review, readiness, and
  current-head verification workflow in `AGENTS.md`.
- Do not run `install.ps1` unless live deployment was explicitly authorized.
