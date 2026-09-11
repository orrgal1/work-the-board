---
name: next-issue
description: "Pick the next ready GitHub issue, work it in an isolated git worktree behind a draft PR opened at start, and mark ready, land, or retire it on command. Use for 'work the next issue', 'ready', 'land', or 'done' instructions inside a build session."
---

# Next Issue

Own one issue end to end: select it, isolate it in a worktree, implement it there, then
land or retire it only on explicit instruction.

## 1. Find the next available issue

```bash
gh issue list --state open --limit 200 --json number,title,labels,body
```

Ready = open, carrying none of `mgr:in-flight`, `mgr:hold`, `research`, and every
`Blocked by: #N` reference either absent or itself closed. Order: `priority:high` first,
then lowest issue number. If nothing is ready, report why (all blocked / all in-flight /
all held / none open) and stop — do not invent one.

Claim it immediately to prevent double-pick:

```bash
gh issue edit <N> --add-label mgr:in-flight
```

**Handed a specific issue?** If a caller (e.g. `work-the-board`) names the issue number
as already claimed, skip this step (verify it still carries `mgr:in-flight`) and go
straight to step 2.

## 2. Create the worktree and rename the tab

```bash
herdr worktree create --branch issue-<N>-<slug> --base main --label issue-<N> --no-focus
```

Read the worktree's absolute path and its tab id from the create result, then rename the
tab to `issue-<N>: <TITLE>` — the watcher's tab sweep matches on that exact prefix:

```bash
herdr tab rename <TAB_ID> "issue-<N>: <TITLE>"
```

## 3. Open a draft PR

Push the branch and open a draft PR immediately, before any implementation work, so the
issue has a visible in-progress artifact:

```bash
git push -u origin issue-<N>-<slug>
gh pr create --draft --fill --head issue-<N>-<slug> --base main --body "Closes #<N>"
```

## 4. Work strictly inside the worktree

Every read, edit, and command for this issue runs rooted at the worktree path — never
the primary checkout. Do not touch files outside it. Do not merge or close anything yet.

## 5. On "ready"

Only when explicitly instructed:

```bash
gh pr ready <PR_N>
```

Run this repo's final review pass and its CI if invocable (`gh pr checks <PR_N> --watch`,
or trigger the workflow if it doesn't run automatically); if unavailable, say so plainly.

## 6. On "land"

Only when explicitly instructed:

```bash
gh pr merge <PR_N> --squash --delete-branch
gh issue close <N> --comment "Landed in <PR_URL>."
gh issue edit <N> --remove-label mgr:in-flight
```

Confirm the merge succeeded (`gh pr view <PR_N> --json state`) before closing the issue.

## 7. On "done"

Only when explicitly instructed, and only after landing (or after being told to abandon
the issue without landing — in that case remove `mgr:in-flight` and leave the issue open
with a comment explaining why, before proceeding):

```bash
herdr worktree remove --workspace <WORKSPACE_ID>
herdr tab close <TAB_ID>
```

Remove the worktree, then close the tab, in that order — a lingering tab looks like a
live session. Use the tab id from step 2; if unrecorded, `herdr tab list` and match the
label prefix `issue-<N>:`. Never close the tab or remove the worktree before landing
unless told to abandon the issue.
