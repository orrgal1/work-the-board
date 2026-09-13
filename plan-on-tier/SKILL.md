---
name: plan-on-tier
description: "Launch a dedicated plan subagent at an operator-chosen tier (1-3) and keep it open for iterative plan review until the operator is satisfied. Use for 'tier 1/2/3 plan' requests."
---

# Plan On Tier

Launch one `plan-tier<N>` subagent, in-session, and keep it alive so the operator can iterate.

The coordinator's provider is authoritative. A tier changes capability within that
provider; it must not select a globally configured model from another provider.

## 1. Get the tier and provider

Use the tier (1, 2, or 3) the operator gave. If none was given, ask — never default.
Read the active coordinator model/provider from the session context, then resolve the
requested tier through that provider's configured tier mapping. Do not use the global
`@tier<N>` role when it resolves to a different provider, and do not invent a model ID
or substitute another provider. If the active provider has no tier mapping, report the
missing mapping instead of launching a cross-provider subagent.

## 2. Launch the plan subagent

Spawn `task` with `agent: plan-tier<N>` and a stable `name` (e.g. `PlanTier<N>`) so you can
address it again. The handoff must state the coordinator provider and the provider-local
model selector used for the requested tier; the tier agent must run on that selector.
Pass the full plan request as its `task`.

## 3. Relay, then iterate

Relay the subagent's plan to the operator verbatim. On feedback, send it to that SAME
subagent by name with `hub` `op: "send"` — a parked subagent keeps its history and wakes on
a message — never spawn a second one for the same plan.

## 4. Stop

Stop resuming once the operator says the plan is good. Nothing to tear down.
