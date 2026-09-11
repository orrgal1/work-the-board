---
name: new-issue
description: "Intake a new GitHub build issue, check it against the current board, dedupe, and place it in its correct dependency lane. Use when the operator wants a new issue filed and slotted onto the board rather than just created."
---

# New Issue

Turn a raw request into one correctly placed, non-duplicate GitHub issue.

## 1. Intake

Take the operator's raw request verbatim: no summarizing, splitting, or writing
acceptance criteria. The issue body is the request, unedited.

## 2. Examine the board

Pull current state before creating anything:

```bash
gh issue list --state open --limit 200
gh issue list --state closed --limit 100
```

Read titles and bodies of plausible matches (`gh issue view <N>`), not just titles.

## 3. Dedupe

- Exact or near match already open → do not create a new issue. Comment the request as a
  note on the existing issue and stop.
- Overlapping but distinct scope → create the issue, then comment a link to the related
  issue(s) on both, noting the overlap. Leave closing/merging to the operator.
- No match → create the issue normally.

## 4. Place in its dependency lane

Determine real prerequisites from the board — issues that must land first for this one
to be buildable (shared files, interfaces, migrations, or explicit sequencing the
operator stated). Then:

- Depends on open issue(s): add `Blocked by: #N, #M` — all referenced numbers on that
  single line. The board watcher takes every number found on `Blocked by:` lines; a
  continuation line without that prefix is not parsed.
- Open issues depend on it: comment the link on those issues (do not rewrite their
  `Blocked by:` yourself unless you own them).
- No real dependency: leave it unblocked; do not invent ordering for convenience.

Also set the lane label if it applies — both keep the issue out of automatic pickup:

- `research` — resolves by a human deciding, approving, or registering something, not by
  a diff. Never auto-picked; dispatch it deliberately.
- `mgr:hold` — nobody should build it yet (operator-owned, or waiting on an outside
  answer). Blocks pickup, costs no concurrency slot. Always comment why.

## Output

Report: issue number/URL, dedupe verdict (created / merged-into-existing / linked-as-related),
and the dependency lane it landed in (`Blocked by:` or none).
