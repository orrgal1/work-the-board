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

**Board is a GitHub Project?** Readiness is the Status field instead of labels: `Todo`
is the ready pool, `In progress` is in flight, `Blocked` is a hold. The `research` label,
`mgr:manual-approve`, and the `Blocked by: #N` body rule still apply exactly as above.
Inspect by hand with `gh project item-list <number> --owner <owner> --format json`.

Claim it immediately to prevent double-pick (repo mode only):

```bash
gh issue edit <N> --add-label mgr:in-flight
```

In project mode, do not add or remove `mgr:in-flight` and do not touch Status yourself —
the watcher is the only writer of Status. A session handed a project-board issue by the
watcher does nothing at all to board state when claiming or releasing it. Running
standalone against a project board with no watcher active: nothing will move the card,
so say so plainly and let the operator set Status themselves.

**Handed a specific issue?** If a caller (e.g. `work-the-board`) names the issue number
as already claimed, skip this step (verify it still carries `mgr:in-flight` in repo mode,
or `In progress` in project mode) and go straight to step 2.

**Handed a tab by `work-the-board`?** With multi-board configs the watcher names the tab `<board>/issue-<N>: <title>` and the agent `<board>-issue-<N>` — use those exact names rather than deriving `issue-<N>` yourself. A watcher-launched session is always started inside the target repo's own herdr workspace by the watcher itself, so it always hits the common case in step 2 below, never the fallback.

## 2. Create the worktree and rename the tab

Isolate the issue with a plain git worktree — never `herdr worktree create`, which always
spins up a brand-new, separate herdr workspace as an unavoidable side effect and is
exactly the bug this skill must not reintroduce:

```bash
git -C <primary checkout path> worktree add <new checkout path> -b issue-<N>-<slug> main
```

Adopting an existing branch instead of cutting a fresh one? Base off that branch instead
of `main`, same as before — only the mechanism changed, not the branch-selection logic:

```bash
git -C <primary checkout path> worktree add <new checkout path> <existing-branch>
```

Immediately after either `worktree add` command above, verify the new worktree is
actually parented to this repo before doing anything else with it. The real risk with
plain `git worktree add` is a wrong `<primary checkout path>` — most likely when the
pane is not yet in this repo's own workspace (the rare fallback below) — so the check
must not itself depend on `<primary checkout path>`: comparing the new worktree back
against the very value that built it never catches that value being wrong. Anchor
instead on the repo identity you already know independently — the one you were told
to work on (a board's configured `repo`, or the directory the operator pointed you
at), never re-derived from the possibly-wrong `<primary checkout path>` value you
substituted into the add command above:

```bash
git -C <new checkout path> remote get-url origin
```

A worktree shares its parent checkout's `.git/config`, so this origin names the
*parent* repo — confirm it matches the repo you were told to work on, not some other
repo the pane happened to be sitting in. Separately, confirm the path is a worktree
root and not merely a directory nested inside one (upward directory discovery would
otherwise let a stray leftover subdirectory pass the origin check too, since it
inherits the same repo identity):

```bash
test "$(git -C <new checkout path> rev-parse --path-format=absolute --show-toplevel)" = "$(cd <new checkout path> && pwd -P)"
```

Treat a failed origin match, a failed toplevel match, or either command failing
outright (stranded outside any repo entirely), as the same verdict: this
worktree does not belong to this repo. Do not proceed with it, and do not commit,
push, or file anything against it. Remove it by addressing the worktree itself, not
the assumed primary — this resolves the owning repo through the worktree's own gitfile
and works even when the worktree turned out to be parented to a different repo
entirely:

```bash
git -C <new checkout path> worktree remove <new checkout path>
```

If that itself fails because the path isn't a worktree at all (creation failed
outright), delete the directory and run `git worktree prune` in whichever repo's
`worktree list` still references it. Then re-create against the corrected primary
checkout path and report the misplacement. If the corrected re-creation fails the same
check again, stop and report — do not loop on repeated remove/re-create attempts.

**Never repair a misplaced worktree by rewriting its remote.** `git remote set-url`,
`git remote add`, and similar are never valid repairs here, because a worktree shares
its parent repository's `.git/config` — "fixing" the origin on a misplaced worktree
actually rewrites the *primary* checkout's origin instead, and a following fetch can
pull a foreign repo's refs into it (this has happened: it moved a primary checkout's
`origin/main` to a different project's history entirely). The only valid repair is
remove and re-create.

The worktree verified, take two records now, before any implementation work, regardless of which tab case applies below:

```bash
realpath <new checkout path>                        # the absolute worktree path every subagent brief will carry
git -C <primary checkout path> status --porcelain -uall   # the primary checkout's pre-existing dirt — the baseline
```

Record `<new checkout path>` absolute because step 4 forbids relative paths in subagent briefs. The baseline is what "clean" means for this session: whatever it lists now was there before this session started and is not yours to touch — or to clean up. See "Leave the primary checkout as you found it" below.

Before touching any tab, decide which of the two cases below applies — that decision is
conceptually the first thing to do, ahead of any tab action, though the two `worktree
add` commands at the top of this step are location-independent and may already have
run regardless of which case applies.

**Common case — your pane is already inside the target repo's own workspace.** This is
true for both a watcher-launched session and the ordinary human-started standalone
session. Nothing herdr-specific is needed: just record `<new checkout path>`, root every
subsequent read/edit/command there (see step 4), and rename the tab you are already
running in — no new tab, no new workspace. Use the convention matching how this session
started:

```bash
# Watcher-launched session: use the board's tab convention
herdr tab rename "$HERDR_TAB_ID" "<board>/issue-<N>: <title>"

# Standalone session: use the bare form
herdr tab rename "$HERDR_TAB_ID" "issue-<N>: <TITLE>"
```

Get this right the first time: a tab left in the bare form is invisible to the watcher's
`sweep_finished_tabs` (it only matches `<board>/issue-<N>:`), and a tab in a primary
workspace is unreachable by `sweep_orphan_worktrees` either way — exactly the
label-matching failure this skill exists to avoid.

**Rare fallback — your pane is NOT already inside the target repo's own workspace.**
Check this first, before any tab action: compare `$HERDR_WORKSPACE_ID` against the
repo's own primary workspace id, found with the same reasoning `watch.sh`'s startup
validation uses — a workspace counts as the repo's own primary workspace when its
checkout resolves to the repo's git root and it is not itself a linked worktree. The jq
below does a plain string match, so resolve the canonical root first and substitute that
(not a relative or symlinked path) for `<primary checkout path>`. The worktree guard
above already ran before this point and validated `<primary checkout path>` against
the worktree it produced, so this lookup is trusting a value that check has already
covered, not a fresh unchecked one:

```bash
primary_root=$(git -C <primary checkout path> rev-parse --show-toplevel)
herdr workspace list | jq -r --arg root "$primary_root" '.result.workspaces[] | select(.worktree.checkout_path == $root and .worktree.is_linked_worktree == false) | .workspace_id'
```

If `$HERDR_WORKSPACE_ID` differs from that id, relocate your own running pane there
first:

```bash
herdr pane move "$HERDR_PANE_ID" --workspace <repo_workspace_id> --new-tab --no-focus
```

Then immediately re-apply the tab label from the move's own response — do this in the
same breath, before anything else:

```bash
herdr tab rename <new-tab-id-from-move-result> "issue-<N>: <TITLE>"
```

**Trap:** `pane move --new-tab` silently replaces whatever label the destination tab had
with a bare number. Skip the immediate rename and the tab becomes invisible to every
label-matching sweep. `$HERDR_PANE_ID` is always present as an env var inside a
herdr-managed pane, but after the move `$HERDR_WORKSPACE_ID`/`$HERDR_TAB_ID` still name
the OLD (pre-move) tab/workspace, not the new one — capture the new tab and workspace ids
from the `pane move` response itself and use those going forward.

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

Subagents are where this rule breaks: a relative path in a subagent's tool call resolves against this session's base cwd — the primary checkout — not against whatever worktree its brief names. Twice this has written superseded drafts into a primary checkout and blocked its next `git pull --ff-only` there. So every subagent brief — builder, plan, or review — states the worktree as the absolute path recorded in step 2 and requires absolute paths in every file operation it hands out; a brief that names the worktree but passes relative paths is a bug, however clear its intent. The same risk applies to commands, not just file operations: a subagent running a shell command from its own base cwd — a stray `git commit`, a script — can land in the primary checkout without ever touching a file the porcelain compare below would catch, because it operates on git state instead, and can still break `git pull --ff-only` there. So every subagent brief also sets the working directory of every command it hands out to the worktree, or otherwise scopes that command to it explicitly — not just its file read/write paths.

When a subagent's first result comes back, confirm one file it claims to have written actually exists under `<new checkout path>` before building on it — a leak caught at the first slice costs one `read`; caught at the finish line it costs a re-run.

## Leave the primary checkout as you found it

The finish line for this session is any of: a supervised stop-and-report after pushing, closing the issue (landing in step 6, or abandoning in step 7), and removing the worktree in step 7. Before each, re-run the baseline command from step 2 and compare:

```bash
git -C <primary checkout path> status --porcelain -uall
```

The comparison matches by path only, ignoring any status-code change on an already-baselined path — an operator staging a pre-existing modification mid-session is still baseline, leave alone, not a new leak. Every path already in the baseline, by that path-only match, is pre-existing local state — someone's intentional edits, nothing to do with this issue. Leave it alone.

A path new since the baseline is not automatically this session's fault: this session shares the primary checkout with an operator and other tools, and a third party can touch a file there for reasons unrelated to this issue while this session is alive. Restore only the new paths this session can actually attribute to itself — a path a subagent brief named, a path a subagent result claimed to have written, or a path one of this session's own commands touched. Restore each one by its exact path, and only those:

```bash
git -C <primary checkout path> checkout -- <path>    # tracked file modified or deleted
rm <primary checkout path>/<path>                     # untracked file that appeared
git -C <primary checkout path> restore --source=HEAD --staged --worktree -- <path>   # leak that got staged
```

Never `git checkout -- .`, `git restore .`, `git stash`, or `git clean` in the primary checkout: the baseline can hold intentional local edits unrelated to any issue (it has), and a blanket restore destroys them. A path that is in the baseline but that this session may also have written to cannot be restored safely either — leave it and name it in the report instead. The same caution applies to a new-since-baseline path this session cannot attribute to itself by brief, result, or command: leave it and name it in the report too, rather than assuming every non-baseline path is this session's leak. Name every path restored (or left, per the previous two sentences) in the final report; a comparison showing nothing new needs no more than that it passed.

## 5. On "ready"

Only when explicitly instructed:

```bash
gh pr ready <PR_N>
```

Run this repo's final review pass and its CI if invocable (`gh pr checks <PR_N> --watch`,
or trigger the workflow if it doesn't run automatically); if unavailable, say so plainly.

## 6. On "land"

Only when explicitly instructed, and after the primary-checkout comparison ("Leave the primary checkout as you found it") has been re-run after this session's own last file operation, immediately before merging:

```bash
gh pr merge <PR_N> --squash --delete-branch
gh issue close <N> --comment "Landed in <PR_URL>."
gh issue edit <N> --remove-label mgr:in-flight
```

Project mode: skip that last label removal — the watcher reconciles the closed issue's
card to `Done` on its own.

Confirm the merge succeeded (`gh pr view <PR_N> --json state`) before closing the issue.

## 7. On "done"

Only when explicitly instructed, and only after landing (or after being told to abandon
the issue without landing — in that case remove `mgr:in-flight` and leave the issue open
with a comment explaining why, before proceeding), and after running the primary-checkout
comparison ("Leave the primary checkout as you found it") — this session's last chance to
restore anything:

```bash
cd <primary checkout path>
git -C <checkout path> worktree remove <checkout path>
herdr tab close <TAB_ID>
```

Remove the worktree, then close the tab, in that order — a lingering tab looks like a
live session. There is no separate worktree workspace to close: only the one tab this
session has been running in the whole time (its id from the common case, or the
move-result id from the fallback in step 2) needs closing. If unrecorded, `herdr tab
list` and match the label prefix `issue-<N>:`. Never close the tab or remove the
worktree before landing unless told to abandon the issue.

Note: `git worktree remove` addresses the checkout by its recorded `<checkout path>`,
not by the session's live cwd, so the command itself does not care where it is run
from — but this session's own cwd has been inside that checkout since step 4, and once
the removal succeeds that directory is gone. Anything run afterward from a shell still
sitting in it — including the very next `herdr tab close` above — would fail or behave
oddly against a now-deleted cwd. `cd <primary checkout path>` first, as shown above,
before running `git worktree remove`, so nothing that follows executes from a deleted
directory.
