---
name: new-issue
description: "Dedupe a requested GitHub issue and place it in the correct board lane."
---

# New Issue

Create one correctly placed issue from the operator's request.

## Intake and dedupe

Preserve the request verbatim as the issue body. Read the current open issues and likely
closed matches; compare bodies, not titles alone.

- Existing near-identical open issue: add the request as a comment and do not create one.
- Related but distinct work: create it, then cross-link both issues and name the overlap.
- Otherwise create it normally.

## Dependencies and lanes

Add one `Blocked by: #N, #M` line only for prerequisites that must land first. Do not
invent sequencing for convenience or rewrite another owner's issue.

- `research`: completion is a human decision/action rather than a diff; never auto-picked.
- `mgr:hold`: waiting on an external answer or operator action; comment the reason.
- Neither: ready for normal selection.

For a GitHub Project, add the issue to the project and set Status to `Todo`; use `Blocked`
for a real hold. The watcher owns later Status transitions. `research`,
`mgr:manual-approve`, and `Blocked by:` keep their normal meaning.

Report the issue number/URL, dedupe result, related links, and dependency lane.
