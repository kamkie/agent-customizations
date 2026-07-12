# Child Contract Template

Use this template after replacing bracketed fields with live, issue-specific details. Keep every core section, using `none` or `not applicable` with a reason when necessary; remove only optional issue-specific detail. Do not launch the child while any remaining placeholder is unresolved.

```text
You own [work item and independently reviewable outcome] in [repository/project].

Applicable live policy:
- Sources and scopes: [instruction paths, tracker rules, external policy, and precedence].
- Consequences: [contracts, invariants, ownership, delivery, validation, review, and artifact rules that apply].
- Recheck points: [events that require policy or external-state refresh].

Scope:
- Objective: [one bounded outcome].
- Tracking item: [issue or work-item link/id].
- Acceptance criteria: [observable result, evidence, and compatibility or quality conditions].
- Non-goals: [explicit exclusions].
- Owned paths or systems: [authorized mutation surface].
- Forbidden paths or systems: [protected and unrelated surfaces].
- Required collateral documentation: [files or records, or none].

Starting state and dependencies:
- Accepted base: [branch/ref] at [exact SHA or artifact version].
- Required refresh: [fetch/reconcile/check steps immediately before work].
- Permitted fallback base: [ref and exact trigger, or forbidden].
- Dependencies and inputs: [accepted predecessors, artifacts, decisions, and versions].
- Assigned worktree and branch owner: [worktree, branch, and owning task/session].
- Shared resource or file locks: [resource, owner, acquisition/release rule, or none].

Never silently replace the accepted base with a moving ref. A fallback must be authorized, deterministic, resolved to an exact version, and reported before edits begin.

Authority:
| Action | Authority source or trigger | Actor/identity | Prerequisites | Current status |
|---|---|---|---|---|
| [tracker/task/write/commit/publish/review/readiness/merge/deploy/message/delete] | [source] | [actor] | [gates] | [authorized/unauthorized/conditional] |

- Treat unlisted actions as unauthorized. Platform capability is not authority. Passing a gate does not by itself supply authority; it authorizes an action only when applicable live policy explicitly names that gate as the trigger and assigns the actor.
- Authorized external effects: [exactly delegated actions].
- Forbidden external effects: [actions reserved for another actor or approval].
- Secret and identity handling: [approved credential source and non-disclosure rules].

Required work:
1. [orientation and exact-state verification].
2. [implementation or investigation steps].
3. [documentation, evidence, and review preparation].

Validation matrix:
| Contract or risk | Command/method | Expected result | Evidence location | Exact tested version | Retry/contamination rule |
|---|---|---|---|---|---|
| [requirement] | [portable command or method] | [pass condition] | [approved location] | [SHA/version] | [rule] |

Preserve failed, invalid, interrupted, and contaminated attempts. Retry only under the stated rule, rerun every check affected by changed inputs, and never discard earlier failures merely because a later attempt passes. Use the repository-required durable process mechanism for long-running work and reuse an equivalent active job when present.

Artifact and knowledge placement:
| Artifact | Purpose | Destination/retention | Public/private | Cleanup or promotion rule |
|---|---|---|---|---|
| [artifact] | [purpose] | [repository-relative or approved external location] | [classification] | [rule] |

- Commit only portable repository-owned artifacts at repository-relative paths.
- Keep disposable evidence in the repository-approved temporary or external location.
- Promote reusable knowledge into its checked-in owning document when policy requires it.
- Never place credentials, private instructions, sessions, memories, caches, machine-specific paths, or unrelated runtime state in public artifacts or tracker content.

Delivery contract:
- Commit segmentation: [required boundaries and message rules].
- Branch and push behavior: [allowed actions and target remote].
- Draft publication: [required state, actor, and minimum checks].
- Review method: [reviewer/tool, required record, and finding-triage behavior].
- Readiness: [exact-head validation, documentation, checks, and authorization].
- Approval and merge/delivery: [repository trigger and actor, or explicitly forbidden].
- Force-push, history rewrite, branch deletion, and cleanup: [authorization and restrictions].
- Integration-state verification: [repository-defined integration ref and required post-action evidence].

Stop and return control when:
- policy, authority, base provenance, ownership, or a required lock is ambiguous;
- required scope expands beyond owned paths or the approved objective;
- validation is contaminated, contradictory, or cannot support the requested claim;
- an external action lacks authority or a live gate fails;
- [additional issue-specific stop conditions].

Terminal handoff:
- Execution state: [COMPLETE / BLOCKED], with blocker or stop reason [details or none].
- Outcome: [ACCEPT / ACCEPT ENABLER/NEUTRAL / REJECT / INCONCLUSIVE/DEFER].
- Recommendation and practical impact: [evidence-bounded conclusion].
- Exact input: [base ref and SHA/artifact version].
- Exact output: [branch, commit/tree SHA, artifact version, or no change].
- Diff and scope summary: [owned changes and confirmation of unrelated preservation].
- Validation: [matrix results, exact tested version, commands/methods, and evidence].
- Artifacts and knowledge: [locations, classifications, retention, and cleanup status].
- Task/worktree/branch ownership: [task/session, worktree, branch, and clean-state result].
- Policy and authority rechecks: [sources, checkpoints, and exact-version results].
- External actions: [authorized actions performed and reserved or unauthorized actions withheld].
- Shared locks: [acquisition, ownership, release evidence, and final state].
- PR/delivery state: [remote branch, PR/link, exact head, draft/ready state, checks, reviews, approvals, or not applicable].
- Integration state: [live integration ref/result, or not changed].
- Deviations, retries, contamination, limitations, and unresolved findings: [details or none].
- Next requested action: [specific transition], with authority [present/conditional/absent].

Return evidence and a recommendation only. Do not declare the child accepted, advance the campaign's accepted integration state, or start dependent work; wait for the controller's terminal-handoff audit.
```
