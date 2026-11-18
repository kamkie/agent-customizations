---
name: clean-copy
description: Write, review, or trim copy for defined interface behavior, including labels, hints, empty states, error text, toasts, and confirmations. Remove text the screen already makes clear and preserve information users need to act. Skip general prose proofreading, visual styling, whole-flow UX reviews, and decisions about what the interface should do.
---

# Clean interface copy

Use the visible screen and its relevant states to decide whether each string
earns its place. Read it beside the control, value, or action it describes. If
the surrounding context is missing, state the assumption behind a proposed cut.

## Decide what to keep

1. Identify what the user needs to understand, decide, or do at that moment.
   For new copy, start with that information. For existing copy, flag text
   that answers an unprompted concern or repeats a nearby label, value, or
   action. A heading called “Profile photo” can carry the meaning of a caption
   that says “This is your profile photo.”
2. Look for warnings that defend a settled design or address a past failure.
   Before cutting one, check the relevant behavior or current documentation.
   Keep the warning if the condition still applies or you cannot verify it.
   Explain a current limitation in the state where it matters.
3. Preserve information that changes a decision or lets someone act. Keep
   action and accessible names, units or input formats, eligibility and
   compatibility limits, consequences of irreversible actions, and status or
   recovery instructions users cannot infer. An empty state should explain
   what is missing and identify the next available action when there is one.
   Keep applicable legal, safety, and accessibility disclosures. Before
   cutting text that labels or describes a control, check how the control gets
   its accessible name and description. Keep the text if removing it would
   take away needed information from assistive technology users.
4. Cut the redundant clause and keep the useful part. When the whole hint is
   redundant and an edit is authorized, remove the hint prop or element and
   any description reference that would point to it. Preserve control behavior
   and meaningful feedback. For localized text, check for remaining uses
   before removing translation keys. Update affected tests to cover the
   intended copy and behavior.

## Deliver the result

For a review, give the location (file and line when available), current text,
proposed replacement or removal, and a brief reason. Leave copy that passes
alone. For new copy, give the proposed text in its UI context. For authorized
edits, check the affected state and any label or description relationship.
