---
name: plan-on-tier
description: "Launch one internal planning subagent at an operator-chosen tier and keep it available for follow-up."
---

# Plan On Tier

Use this skill for an explicit tier 1, 2, or 3 plan. If no tier was supplied, ask.

## Dispatch

1. Confirm the current session has an executable provider-local mapping for
   `plan-tier<N>` before dispatch. Missing or cross-provider routing is a hard error:
   report it and stop. Never downgrade, switch providers, or use another process.
2. Launch one genuine internal `plan-tier<N>` task with a stable name. Pass the full
   request, concrete repository/worktree, constraints, and required output.
3. Accept the result only when task runtime metadata identifies the requested role and
   the expected provider/model. Prompt text and a role file are not routing evidence.
4. Relay the plan. Send revisions to the same child with `hub`; do not restart the plan.

The issue coordinator stays alive in its existing pane throughout. Planning never starts
an OMP process, agent process, helper tab, operation session, or headless/background
fallback. Configuration must be loaded before internal task dispatch; the skill does not
rewrite configuration or restart the coordinator to make a failed dispatch appear valid.
