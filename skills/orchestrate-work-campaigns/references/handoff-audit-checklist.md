# Terminal Handoff Audit Checklist

Use this checklist before accepting a child result, advancing the accepted integration state, starting dependent work, or crossing a readiness, merge, or delivery gate. A child report is a claim until the controller verifies it against exact live state.

## 1. Freeze and identify the child state

- Record the visible task/session, assigned worktree, branch owner, expected input SHA, actual base SHA, output HEAD or artifact version, and resource-lock state.
- Inspect authoritative worktree registration, such as `git worktree list --porcelain`, and prove the task still owns the reported worktree and branch.
- Confirm the worktree is clean except for explicitly reported artifacts and that no equivalent task, branch, job, experiment, or PR has replaced or duplicated it.
- Preserve the audited refs and evidence. Do not let a moving branch name substitute for an exact SHA.

## 2. Verify contract, scope, and repository state

- Re-read the child's objective, non-goals, owned and forbidden paths, dependencies, authority, validation contract, and stop conditions.
- Compare the expected input with the actual merge base and inspect the complete input-to-output diff and commit list.
- Confirm every changed and untracked path is authorized, collateral documentation is handled, unrelated work is preserved, and the reported clean state is accurate.
- Record unauthorized, unexplained, generated, or missing changes as discrepancies rather than silently repairing them.

## 3. Verify validation, evidence, and limitations

- Bind every validation command or method, result, review record, and artifact to the exact audited output version.
- Confirm required validation ran with the specified inputs, retry rules, and environment and that failed, invalid, interrupted, or contaminated attempts remain visible.
- Inspect retained evidence read-only. Rerun validation only through the owning task or an authorized audit task after acquiring applicable resource locks and using the required isolated or non-mutating environment. Otherwise return the handoff for revalidation. Record any new attempt separately.
- Verify artifact locations, privacy classification, retention, cleanup, evidence provenance, practical impact, limitations, and unsupported claims.

## 4. Verify remote delivery state when applicable

- If the child contract has no remote branch or PR, record `not applicable` with the reason and verify the domain-equivalent exact artifact and delivery state instead.
- Otherwise, fetch or freshly query remote state and prove the remote branch and PR head equal the audited output HEAD.
- Read draft or ready state, required checks, approvals, review comments, and unresolved threads for that exact head under current repository policy.
- Confirm every actionable finding is resolved or explicitly blocks the transition.
- Invalidate and refresh affected checks, reviews, approvals, and audit evidence after any push, force-push, rebase, merge, or head change.

## 5. Perform an authorized terminal action

- Recheck the authority source or repository-defined trigger, required actor, exact-head gates, merge order, target ref, and current external state immediately before acting.
- Use a head-match guard when the hosting system supports one. Do not merge, enable auto-merge, deploy, notify, delete, or clean up merely because the platform permits it.
- For auto-merge, record the guarded head and monitor until it completes or stops; enabling it is not completion. Only after the PR reports merged, freshly prove its final head equals the audited authorized head and its reported merge/squash/rebase result belongs to that PR. Fetch the configured target remote/ref, record the result SHA and fresh target tip, then prove the result is reachable from the target tip. Tip equality is not required when unrelated commits may land concurrently.
- Advance the accepted state only after the repository topology's post-action proof succeeds.

## 6. Record the audit outcome and campaign decision

Use an audit outcome separate from the child's campaign recommendation:

- `VERIFIED`: the handoff identity and evidence are trustworthy; the controller may make the authorized campaign decision.
- `RETURN`: correction or revalidation belongs in the same task/session and worktree.
- `BLOCKED`: recovery requires new authority or unavailable external state.

A verified recommendation can still be accepted, excluded, or deferred. Record the decision, exact previous and resulting accepted states, evidence, limitations, and next authorized action.

## 7. Recover without losing ownership or provenance

- Resume the same visible task/session and worktree for corrections whenever possible.
- If the task cannot resume, return `BLOCKED`. Transfer ownership or create a replacement task/worktree only with explicit authority, carrying forward the original contract and audit discrepancies.
- Do not edit, cherry-pick, rebase, commit, merge, or repair child work in the controller checkout.
- Do not create a replacement task, worktree, branch, job, experiment, or PR without explicit authority. If replacement is approved, mark the original superseded before another task owns its branch or worktree, and preserve its evidence.
- Retain resource locks until the owning task is safely resumed, superseded, or audited as released.

## Audit Record

```markdown
# Terminal handoff audit: [work item]

- Visible task/session: [link/id and state]
- Worktree and owner: [worktree, task, and registration evidence]
- Branch and remote: [local/remote branch]
- Expected input / actual base / output: [exact SHAs or artifact versions]
- Diff and commits: [range, summary, and scope result]
- Clean state and resource locks: [evidence]
- Validation and artifacts: [exact-version results, evidence, and limitations]
- PR and exact head: [link, head, draft/ready state]
- Checks, approvals, reviews, and threads: [live exact-head state]
- Audit outcome: [VERIFIED / RETURN / BLOCKED]
- Child recommendation: [ACCEPT / ACCEPT ENABLER/NEUTRAL / REJECT / INCONCLUSIVE/DEFER]
- Controller decision: [accepted / excluded / deferred / pending authority]
- Previous and resulting accepted state: [exact versions]
- Recovery or next action: [action, owner, authority status]
- Delivery proof, if applicable: [merge result, fetched target ref/tip, reachability evidence]
```
