---
name: plan-on-tier
description: "Launch a dedicated plan subagent at an operator-chosen tier (1-3) and keep it open for iterative plan review until the operator is satisfied. Use for 'tier 1/2/3 plan' requests."
---

# Plan On Tier

Launch one `plan-tier<N>` subagent, in-session, and keep it alive so the operator can iterate.

The coordinator's provider is authoritative. A tier changes capability within that
provider; it must not select a globally configured model from another provider.

## 1. Resolve and load the provider-local tier

Use the requested tier (1, 2, or 3) and the coordinator's actual provider/model
metadata. Resolve that tier from the provider's configured mapping; never infer a
model from the global `@tier<N>` role or from handoff prose. The mapping must be an
actual model selector for the same provider, and a missing mapping is a hard error.

Task agents are created before their prompt is delivered, so this cannot be fixed by
putting the selector in the handoff. Before spawning, create a temporary config
overlay containing only the executable override:

```yaml
task:
  agentModelOverrides:
    plan-tier<N>: <resolved-provider-local-selector>
```

Checkpoint the coordinator, quit only its OMP process (leave the issue tab open), then
resume the same session in the same pane and with the overlay loaded:

```bash
checkpoint
/quit
herdr agent start <same-agent-name> <same-pane-id> -- \
  --resume <same-session-path> --config <temporary-overlay>
```

Do not create a helper tab/process or retry a failed provider. The overlay is
session-scoped and must not modify global configuration. Confirm the child metadata
reports the expected `resolvedModel` and provider before accepting its plan; model
role text, task text, and a successful process start are not evidence.

## 2. Launch the plan subagent

Spawn `plan-tier<N>` with a stable name so follow-up messages address the same child.
The handoff states the provider and resolved selector for auditability, but the
overlay above is the routing mechanism. 

## 3. Relay, then iterate

Relay the subagent's plan to the operator verbatim. On feedback, send it to that SAME
subagent by name with `hub` `op: "send"` — a parked subagent keeps its history and wakes on
a message — never spawn a second one for the same plan.

## 4. Stop

Stop resuming once the operator says the plan is good. Nothing to tear down.
