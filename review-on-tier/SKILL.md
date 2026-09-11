---
name: review-on-tier
description: "Launch a dedicated code review agent on an operator-chosen tier (1-3), same model provider as the current session, and keep it open for iterative review discussion until the operator is satisfied. Use for 'tier 1/2/3 review' requests."
---

# Review On Tier

Launch one `review-tier<N>` subagent, in-session, and keep it alive so the operator can iterate.

## 1. Get the tier

Use the tier (1, 2, or 3) the operator gave. If none was given, ask — never default.

## 2. Launch the review subagent

Spawn `task` with `agent: review-tier<N>` and a stable `name` (e.g. `ReviewTier<N>`) so you
can address it again. Pass a concrete target (diff, PR number, branch, or file set) and what
to check as its `task` — the agent itself will refuse a bare "review this". The tier maps to
a role ref (`@tier<N>`) resolved from the operator's `modelRoles`, never a hardcoded model id
— the active model package is what picks the provider and model behind that role.

## 3. Relay, iterate, stop

Relay the subagent's findings to the operator verbatim. On feedback (challenge a finding,
re-check after a fix, narrow scope), send it to that SAME subagent by name with `hub`
`op: "send"` — a parked subagent keeps its history and wakes on a message — never spawn a
second one for the same review. Stop resuming once the operator says the review is done;
nothing to tear down.
