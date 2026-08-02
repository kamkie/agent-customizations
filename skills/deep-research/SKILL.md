---
name: deep-research
description: Investigate difficult, current, or consequential questions through scoped multi-source research, primary-source verification, independent evidence streams, contradiction checks, and citation auditing. Use for technical investigations, product or vendor comparisons, benchmark analysis, literature reviews, current-state assessments, and decision memos. Do not use for simple lookups, routine codebase investigation, implementation work, or requests that only reformat or summarize supplied material.
---

# Deep Research

Produce a defensible answer whose important claims can be checked against the
underlying evidence. Keep the investigation read-only unless the user separately
authorizes an artifact, repository change, or external action.

## Establish the Research Contract

1. Read the active repository and global instructions before gathering evidence.
2. Resolve the exact question, research cutoff, intended audience or decision,
   material claims, and meaningful inclusion or exclusion boundaries from the
   request and available context. Use the current date as the cutoff when the
   user does not provide one.
3. Ask only when a genuinely missing choice would materially change the
   investigation. Otherwise state the assumption and continue; do not stop after
   presenting a plan.
4. Divide broad work into independent evidence streams. Keep tightly connected
   arguments, proofs, and root-cause investigations sequential.

## Gather and Test Evidence

- Use live web access for current or externally verifiable claims. Prefer an
  applicable connector or official documentation source when it can access the
  requested material directly.
- Open and inspect the underlying source. Never rely on a search snippet as
  evidence.
- Prefer primary sources: official documentation, standards, research papers,
  regulatory filings, release notes, original datasets, and first-party
  methodology. Test vendor claims against strong independent evidence when it
  exists.
- Seek at least two independent sources for consequential or disputed claims
  when available. Do not manufacture consensus when only one credible source
  exists.
- Record, in working context, each source's title, author or organization,
  publication or update date, event date when different, URL, exact supported
  claim, relevant methodology, and limitations.
- Verify versions, geography, units, sample size, benchmark configuration,
  hardware, pricing basis, and usage limits whenever they affect comparison.
  Treat incomparable setups as incomparable.
- Search explicitly for counterevidence, failed replications, regressions,
  limitations, and conflicts of interest.
- Separate established fact, evidence-supported inference, and speculation.
  Put citations next to the claims they support and keep quotations brief.

## Delegate Independent Streams

Delegate when the investigation has at least three genuinely independent
evidence streams and active instructions allow agent delegation. Use the
sequential path when delegation would fragment one coherent argument.

1. Discover the current agent capacity and supported model settings. Never
   assume a fixed thread count or launch duplicate workers. Queue excess streams
   when capacity is lower than the planned work.
2. Assign each scout one bounded question with explicit inclusion and exclusion
   criteria, the research cutoff, source priorities, and a stop condition. Tell
   it to return once the evidence contract is satisfied or to report the
   unresolved gap when authoritative evidence remains unavailable. Require:
   - scope handled;
   - findings without a final cross-stream conclusion;
   - an evidence ledger with claim, URL, date, methodology, and limitations;
   - contradictions; and
   - remaining gaps.
3. Prefer a current, efficient model suited to read-heavy research and high
   reasoning when the runtime advertises one. Use explicit model names only
   after confirming availability, and use a bounded context fork when an
   override requires it.
4. Wait for every requested scout, then audit the returned sources and claims
   before accepting them into the consolidated evidence. If a scout keeps
   expanding scope, ask it to conclude with current evidence; if it remains
   stalled, interrupt it and treat unreturned evidence as a gap rather than
   silently accepting or replacing it.
5. For consequential or publication-quality work, give the consolidated
   evidence to one independent skeptic. Prefer the strongest currently
   supported model and a high or maximum supported effort; provide the evidence
   and quality criteria without revealing the intended conclusion.
6. Repair unsupported, stale, or contradictory claims with targeted research.
   The parent agent performs the final synthesis unless the user explicitly
   requests a different ownership model.

Do not create an on-disk ledger, task hierarchy, or progress artifact merely to
represent the workflow. Create a research artifact only when the user requests
one.

## Run the Sequential Path

When delegation is unavailable or would harm coherence, complete separate
passes for:

1. primary evidence;
2. independent evidence;
3. counterevidence and known failures;
4. chronology and freshness; and
5. a final skeptical audit of the consolidated claims.

Keep one coherent working evidence set and revisit earlier conclusions whenever
later evidence conflicts with them.

## Apply the Final Quality Gate

Before answering, verify that:

- every material number, date, comparison, quotation, and current-state claim
  has direct support;
- each citation supports the exact nearby claim and was opened during the
  investigation;
- publication dates and event dates are not confused;
- stale sources, version differences, and benchmark incompatibilities are
  explicit;
- credible disagreement is represented rather than averaged away;
- recommendations state the assumptions that could change them;
- conclusions do not exceed the evidence; and
- no source, fact, quotation, or citation was invented or inferred from a
  search snippet.

If key evidence remains unavailable or contradictory, report bounded
uncertainty and the unresolved gap instead of presenting false completeness.

## Deliver the Result

Use the smallest report structure that keeps the reasoning auditable. For a
substantial investigation, include:

1. bottom line;
2. scope, assumptions, and research cutoff;
3. findings ordered by decision importance;
4. evidence and comparisons;
5. contradictions, uncertainty, and limitations; and
6. practical implications or a recommended action.

Keep citations inline and link directly to the supporting sources. Report any
material validation that could not be completed and why.
