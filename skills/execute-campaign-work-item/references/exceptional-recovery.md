# Exceptional Worker Recovery

Use this reference only when the normal worker path cannot continue. Preserve
the task, worktree, branch, evidence, and ownership until recovery is recorded.
Preserve the original contract unless a later direct user instruction changes
it; that instruction follows the contract-delta protocol in `SKILL.md`.

## Starting-state or ownership mismatch

- Stop before writes when the assigned ref or SHA, worktree registration,
  branch owner, clean state, dependency, or lock differs from the contract.
- Report expected and actual state. Do not reset, stash, rebase, switch branches,
  transfer ownership, or choose a moving fallback unless the contract explicitly
  authorizes that exact action and trigger.

## Scope or authority expansion

- Preserve the partial result and return `BLOCKED` when completion requires an
  unowned path, additional work item, new external effect, different actor, or
  unavailable gate.
- State the smallest controller decision that would unblock progress. Do not
  create the adjacent work, sibling task, or compatibility path speculatively.

## Invalid or contaminated validation

- Retain failed, interrupted, invalid, and contaminated attempts with their
  inputs and logs.
- Rerun only under the contract's retry rule after removing the contamination.
  Replace invalid attempts instead of treating them as valid evidence, and
  rerun every dependent check affected by changed inputs.
- Return `INCONCLUSIVE/DEFER` when the remaining evidence cannot support the
  requested claim.

## Correction after `RETURN`

- Resume the same task, session, worktree, and branch whenever possible.
- Apply only the audited correction, rerun every invalidated check, refresh the
  exact output and delivery state, and issue a replacement terminal handoff.
- Do not assume earlier checks, reviews, or approvals still apply after a head
  change.

## Direct user correction after audit or deferral

- Notify the controller with the exact correction and identify every audit,
  deferral, validation result, report row, and delivery gate it invalidates.
- Resume the same task and owned repository when the correction is clear and
  authorized. Do not wait for the controller to reapprove the user's decision.
- Use verified exact-ref, read-only inputs from another repository when the
  correction names them as authoritative; keep all writes within owned paths.
- Preserve a prior blocked or deferred result as history, not as a veto over the
  corrected work. Return unresolved safety, policy, ownership, or scope
  ambiguity to the user.

## Unavailable task or irrecoverable state

- Return `BLOCKED` when the assigned task cannot resume or its ownership cannot
  be proven.
- Do not create a replacement task, worktree, branch, job, experiment, or PR.
  The controller must authorize and record replacement, mark the original
  superseded, and transfer the contract and discrepancies explicitly.
