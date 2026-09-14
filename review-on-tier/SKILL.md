---
name: review-on-tier
description: "Launch one internal code-review subagent at an operator-chosen tier and keep it available for follow-up."
---

# Review On Tier

Use this skill for an explicit tier 1, 2, or 3 review. If no tier was supplied, ask.

## Dispatch

1. Confirm the current session has an executable provider-local mapping for
   `review-tier<N>` before dispatch. Missing or cross-provider routing is a hard error:
   report it and stop. Never downgrade, switch providers, or use another process.
2. Launch one genuine internal `review-tier<N>` task with a stable name. Give it a
   concrete diff, PR, branch, or file set and the behavior and risks to inspect.
3. Accept the result only when task runtime metadata identifies the requested role and
   expected provider/model. Prompt text and a role file are not routing evidence.
4. Relay findings. Challenges and post-fix checks go to the same child with `hub`; a new
   full review round gets a new independent child when the issue workflow requires one.

The issue coordinator stays alive in its existing pane throughout. Review never starts
an OMP process, agent process, helper tab, operation session, or headless/background
fallback. Configuration must be loaded before internal task dispatch; the skill does not
rewrite configuration or restart the coordinator to make a failed dispatch appear valid.
