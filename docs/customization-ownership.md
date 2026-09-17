# Customization ownership and skill admission

Use this policy before proposing or reviewing an agent customization. The goal
is to put durable guidance at the narrowest surface that owns it without losing
a reusable workflow or publishing local information.

## Classify the candidate

Classify the rule by its authority and reuse boundary, not by where it happened
to be noticed.

| Classification | Owns | Example |
| --- | --- | --- |
| Global guidance | Stable personal defaults that should govern most work for one agent target, including authorization and tool-use defaults | A personal default to keep long-running commands recoverable |
| Portable skill | A repeated, bounded workflow expressed as verbs and outcomes that remains useful across repositories and can discover target policy | Run, observe, recover, and stop a long-running process while preserving logs |
| Repository-local contract | Rules whose authority comes from a repository, project, or delivery process | This repository requires a named validation command and a particular pull-request handoff |
| Private companion material | Reusable operational knowledge that must not be published, even when it supports a public workflow | An internal service registry containing private endpoints and escalation contacts |
| Runtime or machine-local state | Generated, transient, or machine-bound facts | The identifier and log location of a currently running local process |

When a workflow repeats, look first for repeated verbs and target-policy
discovery. The portable skill should own the reusable actions, decision points,
evidence contract, and safe fallbacks. It should read the active repository's
instructions and other authoritative target sources at runtime rather than copy
their values. The repository-local contract continues to own repository names,
commands, actors, merge rules, and release gates.

A candidate that mixes classifications must be split. For example, a portable
review workflow can be public while an internal project registry stays in a
private companion, and the current review session identifier stays in runtime
state.

## Admit a portable skill

A skill needs evidence of recurring use or a concrete cross-repository need,
a bounded trigger and meaningful exclusions, explicit target/tool compatibility,
a complete normal path, proportionate validation, and a publication/ownership
review. Record these in the PR; session history is evidence to inspect, not
content to import as policy. A machine-local fact or one repository's preference
is not a global default merely because it is convenient to discover.

Examples and helpers must be portable. Keep internal registries, transcripts,
credentials, tokens, absolute machine paths and repository-specific merge rules
in their owning private/local contract. Split mixed proposals at that boundary.

## Instruction sources and deployed surfaces

`global/shared.md` owns the common execution contract and personal defaults.
The manifest renders it once into Codex's replacement base and once into Claude's
global file. Codex's base fragment owns only runtime/tool/rendering details;
Codex AGENTS.md and the Claude overlay hold only target-specific additions.
Generated live files are deployment outputs, never parallel editing sources.

A rule's placement in the Codex base does not authorize external actions or
bypass tool/system constraints. Repository contracts retain their explicitly
assigned local decisions and gates. Keep the base's stock-update review focused
on runtime changes without reintroducing duplicate or conflicting policy.

## Ownership and precedence

Authority flows from the active task and target. Higher-precedence instructions
may narrow or override lower-precedence behavior; a reusable skill cannot grant
authority that the user or repository withheld.

Use this order when sources overlap:

1. The current user's authorized request defines the requested outcome and
   action boundary, subject to system and product constraints.
2. The active repository's `AGENTS.md` and equivalent checked-in instructions
   own repository contracts, including validation, actors, paths, and delivery
   gates.
3. Target overlays own stable agent-specific compatibility or behavior that is
   inappropriate for shared global guidance.
4. Global guidance supplies stable personal defaults where the active
   repository and request are silent.
5. Skills own their bounded portable workflows and must discover and obey all
   applicable higher-precedence target policy.
6. Private companion material may inform an authorized workflow but is not a
   public policy source and must not be copied into reviewed public sources.
7. Runtime state reports what exists now; it is evidence to refresh, not durable
   instruction or authority.

System and product instructions remain above repository-managed customization
surfaces. More deeply scoped repository instruction files take precedence for
the paths they govern. If two same-scope sources disagree, treat the conflict as
drift and resolve ownership instead of choosing whichever instruction is more
convenient.

## Reinforcement versus drift

Duplication is intentional reinforcement only when readers need the same safety
boundary at two routing points, one location is clearly canonical, and the
shorter copy links to or faithfully summarizes that source. Examples include a
README warning that deployment is explicit and the authoritative workflow in
`AGENTS.md`, or a skill entrypoint repeating a critical negative trigger that is
explained in a reference.

Duplication is drift when copies can independently change an actor, command,
scope, gate, or rule; when a portable skill freezes repository policy; or when
no canonical owner is identifiable. Replace drift with a link, runtime policy
discovery, or a deliberately scoped overlay. Reviews should compare every
intentional summary with its canonical source.

## Author the routing surface

Treat a skill's frontmatter description as a routing surface, not a summary of
all instructions. Name the repeated verbs, the objects they act on, the intended
outcomes, and the most important boundaries. Include explicit negative triggers
when adjacent workflows are easy to confuse. A reader should be able to decide
whether to load the skill without reading chat history.

Keep `SKILL.md` focused on the executable workflow, decisions, safety rules, and
links needed on most runs. Move detailed variants, templates, long examples,
and specialized troubleshooting into `references/` as on-demand context. Link
each reference from the decision point that requires it; do not force every run
to load unrelated material. References inherit the same portability,
compatibility, validation, and publication-review requirements as the
entrypoint.

## Review questions

Before approval, a reviewer should be able to answer:

- Which classification owns each part of the proposal, and what is its
  canonical source?
- What repeated verbs route to the skill, and what nearby requests do not?
- Which target policies are discovered at runtime instead of embedded?
- What evidence and validation support admission?
- Are examples portable and free of private, machine-local, generated, or
  repository-specific material?
- Is any duplication deliberate reinforcement with a canonical owner, or is it
  drift that should be removed?
