---
name: work-the-board
description: "Continuously watch the GitHub issue board and keep a fixed number of issues in flight by launching next-issue sessions as capacity frees up. Use for 'work the board' with a concurrency limit."
---

# Work The Board

Keep a fixed count of issues in flight, hands-off: poll the board, select and claim ready issues yourself, and hand each one to a `next-issue` session.

**This session leads; it never builds.** Never work an issue here, and never fan issues out to `task` subagents — that bypasses the worktree/tab/PR lifecycle `next-issue` owns, hides the work from the operator, and leaves nobody able to take "ready"/"land" instructions for it.

## 1. Get concurrency and mode

Use the concurrency the operator gave; if none was given, ask before starting anything — do not default or guess.

Mode is `supervised` unless the operator asks for autonomy ("auto mode", "land them yourself", "don't ask me") — landing without approval is not reversible.

| | supervised (default) | auto |
|---|---|---|
| Session stops | after pushing, with a report | only when the issue is landed and done |
| Landing | operator types `ready`/`land`/`done` in that issue's tab | the session does it itself |
| Tier 2 plan | not requested | required first when the issue is complex |
| Tier 2 review | not requested | mandatory on every issue, before landing |

In auto mode the handout prompt states that it *is* the explicit instruction `next-issue` steps 5–7 require, so sessions don't stall waiting for approval that isn't coming.

The watcher never treats `mgr:manual-approve` as stale: an auto session that hits it leaves the PR ready and reports it waiting on approval instead of landing it. If the operator declares the label stale on this board, clear it off the open issues yourself (step 3) before starting the watcher.

## 2. Name this tab and agent

Rename this session's own tab to `board`, and give its agent the same name so the watcher can report back to it:

```bash
herdr tab rename <TAB_ID> "board"
herdr agent rename <PANE_ID> board     # a session not started via `herdr agent start` has no name
```

## 3. Reconcile the board before starting

`mgr:in-flight` is the capacity signal, so a stale one silently costs a slot forever. Audit every open issue carrying it *before* starting the watcher:

```bash
gh issue list --state open --label mgr:in-flight --json number,title
herdr tab list                     # is there a live session owning it?
gh pr list --state all --json number,state,headRefName,title
```

For each one, classify and act:

| Finding | Meaning | Action |
|---|---|---|
| Its PR is already **merged** | Landing was never finished off | Close the issue citing the PR, remove the label |
| Open PR, complete work, no live session | Done, waiting on the operator | Keep `mgr:in-flight`, add `mgr:awaiting-approval`, tell the operator |
| No session, no PR, no branch | Genuinely stale claim | Remove the label so it re-enters rotation; comment why |
| No session, but a branch/PR exists with partial work | Abandoned mid-flight | Remove the label; the watcher hands the branch to the next session to adopt |
| Operator/adviser-owned, or waiting on an external answer | Real hold, not a builder claim | Swap for `mgr:hold` and comment why |

Do not blanket-clear the label without checking each issue against the table above. Also expect merged PRs whose body never said `Closes #N` — GitHub never auto-closed those, which is how stale ones accumulate.

**What the labels mean here:**

- `mgr:in-flight` — a builder owns it. The only label that counts against concurrency. Set at hand-off, cleared on landing.
- `mgr:hold` — nobody should build it yet (operator-owned, or waiting on an outside answer). Blocks pickup, costs no slot. Always comment why.
- `research` — resolves by a human deciding, approving, or registering something, not by a diff. Never auto-picked; dispatch deliberately.
- `mgr:awaiting-approval` — PR open, work done, operator's call. Keep `mgr:in-flight` alongside it or the work restarts.
- `mgr:manual-approve` — never self-merge; the operator approves.

A hold parked under `mgr:in-flight` silently eats a build slot — keep the two straight. When a `research` issue closes, check what it unblocked before letting the board run: work that resolves by a human act (a signup, an account, an approval) can look ready to the filter while being nobody's diff — give it `mgr:hold` and a comment instead.

## 4. Start the watcher

Read the current workspace id once (`herdr pane current`). Start the bundled script as a persistent background process — do not hand-roll the poll loop inline:

```
hub op="start" name="<project>-work-the-board" application="bash" \
  args=["<skill-dir>/scripts/watch.sh", "<WORKSPACE_ID>", "<CONCURRENCY>", "30", "board", "<MODE>"] \
  cwd="<project dir>" restart="on-failure" persist=true
```

`<skill-dir>` is this skill's absolute directory (given in the invocation prompt's "Skill directory" footer). Args are workspace, concurrency, poll seconds, the report target (pass `board`, see "Reporting"), and the mode (`supervised`/`auto`; unknown mode exits 2).

Switching mode restarts the watcher and only affects sessions launched afterwards; steer already-running ones directly (`herdr agent prompt <issue-N> "..."`) if needed.

The script does, every cycle:

1. Counts open issues labeled `mgr:in-flight` — capacity in use.
2. Selects the **ready** issues: open, carrying none of `mgr:in-flight`, `mgr:hold`, `research`, and every `Blocked by: #N` reference either absent or itself closed. Ordered `priority:high` first, then lowest issue number.
3. Looks for work that already exists for that issue — an open PR whose head branch carries the number or whose title/body *closes* it, else a remote branch carrying the number — so the session **adopts** it instead of opening a second branch and PR. A bare `#N` mention is not enough: PRs routinely name related issues.
4. For each free slot, takes the next ready issue, **claims it** with `mgr:in-flight`, opens a tab, starts an `omp` agent, renames the tab `issue-<N>: <title>`, and hands it the issue number plus adoption instructions. A session that fails to come up has its tab closed and its claim **released**.
5. Sweeps finished tabs (below).
6. Sleeps, then repeats.

**The watcher owns selection and claiming.** Do not spawn a generic session and let it find its own issue — that spawns a throwaway agent and tab every cycle when nothing is ready. Pre-claiming also closes the double-pick race between concurrent launches.

`watch.sh` encodes several `herdr`/`jq` response-shape and shell-quoting pitfalls — see its comments. Reuse it verbatim rather than re-deriving them.

**Reporting.** With a report target, the watcher prompts that agent on material changes only: started/stopped; an issue launched (number, title, tab) and claimed; an issue that **left flight** — landed, closed, or claim dropped elsewhere — with its new state (the only way a session landing its own issue becomes visible from here); any launch failure, and whether the claim was released. Idle cycles are never reported. Sends are fire-and-forget, never `--wait`, so a busy board session cannot stall the loop. Relay these to the operator; they are the board's audit trail.

**Landing is the operator's call.** The handed-over prompt tells a supervised session to stop after pushing and leave `gh pr ready`, merging, closing and worktree removal to explicit instruction given **in the issue's own tab** (`land`, `ready`, `done`) — the board session never sees it. So a `left flight (issue is now CLOSED)` report is normally the operator landing it directly; before raising an alarm, check the owning session's transcript (`herdr agent list` gives its `agent_session` path) rather than the board:

```bash
grep -n '"attribution":"user"' <session>.jsonl   # what the operator actually typed, and when
```

**Tab lifecycle.** On `done` the session removes its own worktree, then closes its own tab. The watcher's sweep is only a backstop for a session that dies, is killed, or exits before teardown: it closes an `issue-<N>:` tab once that issue is CLOSED and its worktree is gone, every cycle. More working tabs than `mgr:in-flight` issues is normal, not a leak — a session outlives its claim (it drops the label and closes the issue on landing, then may keep working, e.g. a post-land review, until it exits).

## 5. Verify one cycle

Follow the log (`hub`, `op: "logs"`, `follow: true`) for one cycle. Each line reads `in-flight=<n> free=<n> ready=<n> launching=<n>`. Sanity-check it against the board:

- `ready=0` while the board plainly has an unblocked, unclaimed issue means the readiness filter is broken. Cross-check with `gh issue list --state open --json number,labels,body`.
- `launching>0` should be followed by an `issue #N launched:` line; confirm a real agent came up, not just a tab:

```bash
herdr pane get <PANE_ID>   # agent_status should be "working" or "idle", not "unknown"
```

A pane stuck at `agent_status: "unknown"` with no session file means the launch failed in a way the script didn't catch; stop the watcher and re-check the `herdr` CLI surface (`herdr tab create --help`, `herdr agent start --help`) before restarting it.

`ready=0` with everything genuinely blocked or claimed is the correct steady state: report that as-is rather than forcing work.

## 6. Stop

Stop the background process (`hub`, `op: "stop"`) and report the last observed in-flight count. Sessions close their own tabs on `done`, so a tab still open after stopping either belongs to a session still finishing its own work, or — if its agent never started (`agent_status: "unknown"`, no session file, per `herdr tab list`) — is a genuine orphan, safe to close by hand with `herdr tab close <TAB_ID>`.
