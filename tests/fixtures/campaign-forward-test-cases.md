# Campaign Forward-Test Cases

Give one case at a time to a fresh agent together with the relevant skill
entrypoint. These are input-only scenarios; do not add answers or a rubric.

## Case 1 — Inventory without publication

Coordinate a dependency upgrade across eight maintained repositories. You may
inspect repositories and the tracker, create an inventory, and update the
tracker. You may not push branches, create or edit pull or merge requests, or
request an external review. Describe the next executable campaign state after
the inventory identifies six applicable repositories.

## Case 2 — Short delivery trigger

Start delivery campaign APP-42. The tracker lists five independent maintained
repositories. Each repository requires a draft merge request, pipeline, and
opposite-agent review before human handoff. The request says nothing about
merging or deployment. Describe the campaign sequence and first team-visible
checkpoint.

## Case 3 — Direct correction in a worker

A controller previously audited a repository as deferred because a bootstrap
schema was incomplete. The user now tells that repository's existing worker
that the missing schema is a product bug to fix and that the work must continue.
The controller still has the earlier audit and report row. Explain the worker
and controller response.

## Case 4 — Authoritative schema in another repository

A worker owns writes in service-a. Its smallest compatible fix needs the schema
definition from service-b at a named commit, but service-b must remain
unchanged. Explain how the worker may use that input and how ownership appears
in its handoff.

## Case 5 — Reconciled reporting

An inventory contains twelve repositories. Nine are applicable: five have
reviewed green draft merge requests, two are blocked, one is deferred, and one
was absent from the controller's summary table. Produce the concise campaign
status and state whether the campaign can be reported complete.

## Case 6 — Local commits only

A controller has clean local commits for every applicable repository, but no
remote branches, merge requests, pipelines, or review records. The private
ledger contains exact SHAs and passing local tests. Produce the campaign outcome
and next authority checkpoint.
