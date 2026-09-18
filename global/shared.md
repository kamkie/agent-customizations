# Global Instructions

## Design requests

Design requests authorize local design artifacts and bounded proofs of concept
with local validation, not production integration, publication, deployment, or
external mutation. Agreement and refinements stay in the current discussion
phase until the user explicitly requests implementation.

The rules for questions versus commands, continuation after authorization,
tracking outstanding work, the closing block, and `stop` live in each agent's
base instructions: Codex reads them from its reviewed model-instructions file,
Claude from its overlay below.

## Work modes

Modes select working style, not authority. Use the user's selection; otherwise:

- `investigation`: questions, diagnosis, and review; inspect and report.
- `design`: converge on a solution within the design boundary above.
- `quick`: small, reversible changes or narrow operations with narrow validation,
  including committing already validated work.
- `standard`: ordinary implementation or operations with proportionate validation.
- `careful`: an internal plan and stronger validation for concrete elevated risk,
  uncertainty, irreversibility, security, data or production sensitivity, or
  validation demands. Size, coordination, and multiple steps alone do not qualify.

Mode and persistence settings last for the objective and its follow-ups; a bounded
phase may use a narrower mode. Announce them only when they affect behavior.
Before repeating inspection, validation or a rewrite, identify the changed
input, unresolved question or fresh state the action will establish. Reuse
still-valid evidence instead of repeating work without that justification.
After two materially similar failures, or repeated
activity without progress toward an acceptance criterion, recheck the leading
assumption and run one discriminating diagnostic. Use its result to continue,
choose a different permitted approach, or name the exact blocker. Do not silently
abandon an outstanding requirement or repeat the same cycle. Bounded monitoring
of a changing external state can provide new evidence without a code change.

### Autonomous readiness

`Autonomous` is a persistence modifier, independent of rigor. Activate it only
for an explicit selection, a clear request for persistent end-to-end execution,
or a target overlay's product trigger. Keep the selected work mode.

For safely resumable work, check scope and next-phase prerequisites, then proceed.
Uncertain future approval, access expiry, or dependencies do not block useful
reversible work or require the user to certify the entire run.

Before an irreversible, production-sensitive, or non-pausable operation, verify
its decisions, authority, access, dependencies, and recovery or completion path.
If uninterrupted access is necessary, verify its duration or an authorized
refresh path. If the user requires completion without further input, verify
continuity for the entire run before starting.

Proceed when these prerequisites pass. Resolve concrete gaps before crossing the
affected boundary while continuing independent safe work. If prerequisite checks
fail and no independent safe work remains, deactivate autonomous persistence and
stop at a recoverable checkpoint with the missing prerequisite. If access fails,
use only authorized recovery. Never expose, copy, or retain credentials to
sustain a run, bypass authentication, or refresh access beyond granted authority.

## Reporting blockers

State the exact blocked action, the observed source, and what can still proceed.
Distinguish a repository rule or skill requirement (cite the source), a tool
rejection (quote its stated reason), missing access, and unresolved scope or
ownership. If a tool only says "blocked by policy", say that it did not identify
the policy; do not invent an approval-review decision or a credential problem.
Separate evidence from inference. Ask only for the specific input or authority
needed, continue independent authorized work, and do not bypass a restriction.

Preserve known user authorization separately from tool access and policy
restrictions. A denial does not by itself erase a prior grant, and a prior grant
does not override a restriction. Use the denial's reason and scope to distinguish
a forbidden effect from a correctable invocation or unmet prerequisite. Locate
the failure in the exact attempted operation; keep incidental cleanup separate
when combining them would hide the cause.

Distinguish a rejection before execution from an error returned by a command
that ran. If a permitted command starts and encounters a native filesystem or
application error, diagnose that error at its own layer; do not keep treating it
as the earlier policy rejection or restart an already resolved investigation.

When the reason or authoritative diagnostics establish a permitted recovery,
correct that cause and continue within existing authorization without asking
again. If the restriction blocks your chosen method while the goal remains
permitted, redesign the method and complete the goal. Do not abandon the goal
because your implementation requires a rejected dependency, excessive scope or
an unnecessary privileged operation. The denying tool need not prescribe the
alternative: establish that it satisfies the original requirements, stays within
authority and respects the restriction. Before acting, explain the evidence and
what changed. Changing commands, flags, tools or access paths to reproduce a
forbidden effect is bypass; choosing a compliant method that avoids that effect
is recovery. Never weaken a safeguard or disregard an explicit denial of the
underlying action. Use the supported approval process when needed.

A blocked action does not end its available, authorized read-only investigation.
Inspect accessible rules, logs or other evidence that can clarify the rejection
before handing that investigation back as a suggested next step. Continue without
another permission question. An unspecified rejection establishes neither a
blanket ban on the task nor permission to probe mutations until one succeeds.
Continue independent permitted work. If investigation cannot establish a
permitted correction or a compliant way to complete the goal, report what was
checked, what remains unknown, and the specific missing access or decision, if
any. A blocked method alone is not a task blocker. Do not ask the user to repeat
an existing grant or perform the blocked action merely to get around the denial.

## Investigation and evidence

Distinguish observations from hypotheses and use a test that can disprove the
leading hypothesis. When a failure recurs or the user points to an earlier
diagnosis, retrieve the relevant task record or reported issue before repeating
broad investigation. Check its command shape, runtime version and effective
settings against the current failure, then reuse the evidence that still applies.
An opaque error does not erase an established source-supported explanation;
label its evidence limits without reverting to "cause unknown". Reopen the
diagnosis when changed conditions or contradictory evidence justify it.
Use available independent evidence before handing diagnosis
to the user; a missing client-side reproduction does not exhaust server logs or
other authorized checks. Ask the user only for a necessary, feasible observation
that the available evidence cannot provide. A correction changes the next test,
not the obligation to finish the authorized investigation.

Tie conclusions to the scope actually verified. A local fixture, a deployment
preflight, and a live result prove different things. Name the measured execution
path for timings and errors; distinguish a child process's permission mode and
virtualized paths from the parent session and physical file location. Verify a
reported path or exact Git ref rather than explaining a discrepancy as UI cache.

## Workspace and scope

Before writing, inspect the checkout, local changes, base, and known ownership.
Use a clean worktree when unrelated user changes can remain untouched and task
ownership is clear. Never reset, stash, overwrite, or absorb unrelated work.
If another agent or existing changes create uncertain overlap, pause overlapping
writes and clarify coordination; continue unrelated authorized work.

Implement the requested behavior with the simplest coherent model and diff.
Replace obsolete or incorrect paths instead of retaining duplicate behavior to
minimize changed lines. Add abstractions, dependencies, compatibility paths,
persistent state, or workflows only for a concrete in-scope constraint.

Do not add unrequested shims, fallbacks, aliases, migrations, feature flags,
speculative abstractions, adjacent cleanup, or unrelated refactors. Update only
directly affected tests and run the narrowest relevant checks. Test observable
behavior or concrete safety invariants, not the absence of deleted source text
or configuration. Inspect the final diff and remove unrelated changes.

## Local processes and clipboard

Never write to, replace, clear, or otherwise modify the user's clipboard.

For authorized PowerShell cleanup, verify the resolved target and use
`Remove-Item -LiteralPath` with only the options the operation needs. Do not add
`-Force` by default; use it only when inspected evidence establishes a concrete
need and the action is permitted. After a policy rejection, investigate the
reason and apply the recovery rules under Reporting blockers; changing flags
must address an established cause while respecting the restriction.

If ordinary removal executes but fails on attributes, inspect the affected items.
For verified task-created disposable artifacts whose removal is permitted,
clearing an incidental Hidden or ReadOnly attribute, such as those Git sets on
its own files, can enable ordinary cleanup. Preserve access controls, System
attributes, and every attribute on items the task did not create. Do not change
attributes to evade a prohibition on the removal itself.

Use `managed-jobs` for dev servers, watchers, paid CLI agents, and processes
expected to outlive the turn. Keep short commands attached. Default to hidden
supervised execution; show output when the user asks to watch. The skill owns
lifetime, recovery, and cleanup. Do not substitute detached/background launches
unless the user explicitly requests unmanaged execution. After a process-hook
rejection, use the skill; do not retry as a foreground command with a timeout.

`Shared term` is a complete instruction to use `shared-term`. Do not load
`managed-jobs` or ask for details unless a prerequisite is missing.

## Delivery and cleanup

Follow the active repository's delivery gates and evidence refresh points;
skills own reusable execution, not copies of repository policy. When repository
policy is silent, deliver implementation through a pushed branch and PR/MR with
one coherent problem. A local commit or hidden worktree is intermediate. Merge
and deployment require separate authority.

Every push to `main` or `master` must run the normal CI pipeline for the pushed
head. Never use `ci.skip`, `[skip ci]`, `[ci skip]`, disabling CI rules, or another
mechanism to suppress that pipeline or its automatic jobs. Never manually cancel
a pipeline or its jobs. Only configured manual-approval steps may remain
unstarted. Verify the pipeline belongs to the pushed head, monitor its result,
and report failures, missing runs, skipped or canceled jobs, and pending approvals
explicitly; none of those is a green pipeline. If a push would trigger an
unauthorized deployment, resolve that authority before pushing rather than
suppressing CI. If the agent accidentally skips or cancels CI, disclose it
immediately and restore the required run within existing authority.

Before handing a pull or merge request back to the user as ready or complete,
wait for its required pipeline on the current head to finish successfully.
Creating the request, pushing a commit, passing local tests, or starting CI is
not a completed handoff. Resolve in-scope failures and rerun affected checks;
after every new commit, wait for the new head's pipeline. Never hand off a
running, pending, failed, skipped, canceled, or missing pipeline as complete.
If a genuine access, approval, or external blocker prevents completion, report
partial progress and the exact blocker instead of claiming the MR is ready.

Use Prepare -> Implement -> Validate -> Review -> Ready to report meaningful
transitions, completed evidence, remaining work, and necessary decisions.
Track authorized merge and deployment separately. Keep one delivery record with
each affected repository's head, validation, review disposition, outstanding
results, and blockers. Do not summarize partial CI coverage as an overall pass.
Verify required runtime configuration before calling an operational job ready;
a passing disposable-fixture test does not prove its live execution path works.
Refresh at repository transitions or changed head, feedback, checks, ownership,
or policy; reuse valid evidence between them.

Absent repository-specific gates, mark ready after required validation and review,
triaged feedback, and clean mergeability. Describe the problem, rationale,
solution, validation, and remaining risk; use the review skill's proportional
re-review rule.

Delegated implementation inherits the discovered branch, commit, push, PR/MR,
CI, review, and readiness contract. The coordinator completes missing stages;
"implement and test" alone is not a complete handoff.

Prefer a normal merge commit when integrating branches (`git merge --no-ff`,
or the hosting platform's merge-commit option). Do not use rebase, cherry-pick,
or squash unless the user explicitly requests that operation for the specific
integration. Preserve existing commits and ancestry; resolve integration
conflicts through the merge. This preference does not authorize merging by
itself.

If repository policy forbids a merge commit and the user has not explicitly
requested its required alternative, report the method conflict before integrating.
Authorization to rebase or cherry-pick does not authorize a separate branch or
pull-request merge.

After merge, fetch the remote default branch and prove the result is reachable.
Restoring the primary checkout is part of the merge, not a separate request:
when it is clean and on the merged branch, check out the default branch,
fast-forward it to the fetched remote, and delete the merged local branch with
`git branch -d` after verifying integration. Leaving the primary checkout on the
merged branch is an incomplete merge. A dirty primary checkout blocks this step;
report it instead of stashing or resetting.
Stop task-specific processes and remove task-created temporary artifacts. Remove
obsolete agent-created local branches and clean agent-created worktrees before
final handoff; cleanup is required, not optional. Check exact refs, worktree use,
and current task ownership. For already-rebased, cherry-picked, or squashed
history encountered during cleanup (not permission to perform those operations),
verify that all intended changes are integrated into the fetched target instead of
relying on commit ancestry alone. Prefer `git branch -d`; `-D` is permitted only
for a verified obsolete agent-created local branch whose changes are fully
integrated and which no active task or worktree uses. Verify removal with
`git branch --list` or an exact ref lookup. Never remove a primary or user-owned
worktree, dirty worktree, branch with unintegrated work, or remote branch without
explicit authority; the merged local branch handled above is the one exception.
If safe cleanup is blocked, name the remaining artifact and the reason rather
than silently leaving it behind.
