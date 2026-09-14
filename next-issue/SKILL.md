---
name: next-issue
description: "Own one GitHub issue in an isolated worktree from claim through reviewed landing and cleanup."
---

# Next Issue

One visible coordinator owns one issue end to end. Use a plain Git worktree, open a draft
PR before implementation, and never edit the primary checkout.

## 1. Select and claim

When the watcher hands over an already-claimed issue, verify `mgr:in-flight` (repo mode)
or `In progress` (project mode) and continue. Standalone selection uses open issues with
none of `mgr:in-flight`, `mgr:hold`, or `research`, whose `Blocked by:` dependencies are
closed; choose `priority:high` first, then lowest number, and claim immediately. In
project mode the watcher alone changes Status.

Adopt an existing issue branch/PR when present; do not create duplicates.

## 2. Isolate before editing

Fetch the remote and create the branch from `origin/main`, not a possibly stale local
`main`:

```bash
git -C <primary> fetch origin main
git -C <primary> worktree add <worktree> -b issue-<N>-<slug> origin/main
```

For adoption, attach the existing branch instead. Verify before proceeding:

```bash
test "$(git -C <worktree> rev-parse --path-format=absolute --show-toplevel)" = "$(realpath <worktree>)"
git -C <worktree> remote get-url origin
```

The origin must match the assigned repository. A mismatch means remove the worktree and
recreate it from the correct primary; never repair it by changing a shared remote.

Record the absolute worktree path, plus the primary's `status --porcelain -uall` and
`rev-parse HEAD`. Those values are the leak-detection baseline. Every command and every
child brief uses the absolute worktree/cwd. Do not touch outside it except a PR-body file
under `/tmp`.

Keep the watcher-provided `<board>/issue-<N>: <title>` tab label. A confirmed standalone
session uses `issue-<N>: <title>`. The issue pane belongs in the repository's configured
primary Herdr workspace; the Git worktree has no Herdr workspace.

## 3. Open the draft PR

Before implementation, push the branch and create a draft PR targeting `main` with
`Closes #<N>`. If GitHub requires a commit, create an empty start commit; it is preferable
to hiding in-progress work.

## 4. Implement and verify

Work only in the worktree. For complex/high-risk work, use `plan-on-tier` first. Planning
and review are genuine internal children of this coordinator; never start another OMP
process, helper tab, operation session, or background/headless fallback.

Fix the source, migrate callers, and remove obsolete paths. Verify the changed behavior
proportionately. Before landing, use `review-on-tier`; fix every real finding and run a
new full review round after material changes. In autonomous mode rounds 1-2 use the plan
tier (tier 2 when no plan ran), with tier 3 from round 3 onward.

## 5. Ready and land

Rewrite the PR body with what changed and why, root cause for bugs, concrete verification,
unfixed observations, and `Closes #<N>`.

- With `mgr:manual-approve`: compare the primary against its baseline, mark ready, keep
  the worktree and claim, report that approval is required, and stop.
- Otherwise, when authorized (including an autonomous handoff): compare the primary,
  mark ready, wait for invocable focused CI, squash-merge, confirm PR state is `MERGED`,
  close the issue, and remove `mgr:in-flight`. Project mode leaves Status reconciliation
  to the watcher.

Do not review the landed commit, deploy, update the live watcher, add follow-up work, or
pick another issue.

## 6. Protect the primary and clean up

Before every terminal handoff—supervised completion, manual-approval wait, merge, explicit
abandonment, and cleanup—compare primary status paths and HEAD with the recorded baseline.
Never blanket restore, stash, clean, or reset the primary. Restore only a new path
attributable to this session; leave and report unknown changes, vanished baseline paths,
or a changed HEAD.

After confirmed landing, move command cwd back to the primary, remove the recorded
worktree, then close this issue tab. For explicit abandonment, first comment the
operator-authorized reason, leave the issue open, and remove `mgr:in-flight`; a real hold
also gets `mgr:hold`. Project mode reports the disposition and leaves Status changes to
the watcher. Under manual approval cleanup waits until the eventual landing session.
Report PR/issue state, review findings and responses, verification evidence, primary
comparison, and cleanup.
