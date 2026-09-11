---
name: plan-on-tier
description: "Launch a dedicated plan subagent at an operator-chosen tier (1-3) and keep it open for iterative plan review until the operator is satisfied. Use for 'tier 1/2/3 plan' requests."
---

# Plan On Tier

Launch one `plan-tier<N>` subagent, in-session, and keep it alive so the operator can iterate.

## 1. Get the tier

Use the tier (1, 2, or 3) the operator gave. If none was given, ask — never default.

## 2. Launch the plan subagent

Spawn `task` with `agent: plan-tier<N>` and a stable `name` (e.g. `PlanTier<N>`) so you can
address it again. Pass the full plan request as its `task`. The tier maps to a role ref
(`@tier<N>`) resolved from the operator's `modelRoles`, never a hardcoded model id — the
active model package is what picks the provider and model behind that role.

## 3. Relay, then iterate

Relay the subagent's plan to the operator verbatim. On feedback, send it to that SAME
subagent by name with `hub` `op: "send"` — a parked subagent keeps its history and wakes on
a message — never spawn a second one for the same plan.

## 4. Stop

Stop resuming once the operator says the plan is good. Nothing to tear down.
