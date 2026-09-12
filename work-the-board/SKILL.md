---
name: work-the-board
description: "Continuously watch the GitHub issue board and keep a fixed number of issues in flight by launching next-issue sessions as capacity frees up. Use for 'work the board' with a concurrency limit."
---

# Work The Board

Keep a fixed count of issues in flight, hands-off: poll the board, select and claim ready issues yourself, and hand each one to a `next-issue` session.

**This session leads; it never builds, and it never does other work itself either.** Never work an issue here, and never fan issues out to `task` subagents — that bypasses the worktree/tab/PR lifecycle `next-issue` owns, hides the work from the operator, and leaves nobody able to take "ready"/"land" instructions for it. The operator can also type anything else into this tab while the watcher runs — a bug, a feature, research, an in-place operation — route it per "Route other operator input" below instead of acting on it here.

## 1. Get concurrency and mode

Concurrency and mode are per board, required, never defaulted. For one board, use the concurrency the operator gave; if none was given, ask before starting anything — do not default or guess. For several boards, the operator supplies concurrency and mode for each board in the config file (see "Running several boards" below); there is no session-wide default to fall back on for any of them.

Mode is `supervised` unless the operator asks for autonomy ("auto mode", "land them yourself", "don't ask me") — landing without approval is not reversible.

| | supervised (default) | auto |
|---|---|---|
| Session stops | after pushing, with a report | only when the issue is landed and done |
| Landing | operator types `ready`/`land`/`done` in that issue's tab | the session does it itself |
| Plan | not requested | required first when the issue is complex — tier 2 standard, tier 3 for mission-critical/high-risk work (auth/permissions, money, data loss or irreversible operations, schema/migrations, the board's own control plane) |
| Review | not requested | mandatory on every issue, before landing — at the plan tier for rounds 1-2 (tier 2 if no plan ran), tier 3 from round 3 on |

In auto mode the handout prompt states that it *is* the explicit instruction `next-issue` steps 5–7 require, so sessions don't stall waiting for approval that isn't coming.

The watcher never treats `mgr:manual-approve` as stale: an auto session that hits it leaves the PR ready and reports it waiting on approval instead of landing it. If the operator declares the label stale on this board, clear it off the open issues yourself (step 3) before starting the watcher.

**Board mode.** Repo mode (default): the `mgr:*` labels below are the state machine. If the operator names a Projects v2 board ("work the board on project acme/7"), start the watcher with the trailing flag `--project <owner>/<number>` — project mode exists for multiple independent boards over one repo, or one board spanning repos. There the board's single-select **Status** replaces the `mgr:*` capacity labels: `Todo` = ready pool, `In progress` = in flight (the only status counting against concurrency), `Blocked` = hold (no pickup, no slot), `Done` = finished. `research`, `mgr:manual-approve`, and the `Blocked by: #N` body rule are issue properties, not board state — they apply unchanged in both modes. The watcher is the only Status writer: it claims to `In progress`, restores `Todo` on a failed launch, and moves a CLOSED issue's card to `Done`; sessions never touch Status, and a human dragging a card is authoritative — the watcher observes and reports the move, never fights it. Prerequisite: the gh token needs the `project` scope, or the watcher exits at startup naming the remedy (`gh auth refresh -s project`).

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

In project mode, run the same audit over the board's `In progress` cards instead — Status edits (drag to `Todo`/`Blocked`) take the place of label edits.

**What the labels mean here:**

- `mgr:in-flight` — a builder owns it. The only label that counts against concurrency. Set at hand-off, cleared on landing.
- `mgr:hold` — nobody should build it yet (operator-owned, or waiting on an outside answer). Blocks pickup, costs no slot. Always comment why.
- `research` — resolves by a human deciding, approving, or registering something, not by a diff. Never auto-picked; dispatch deliberately.
- `mgr:awaiting-approval` — PR open, work done, operator's call. Keep `mgr:in-flight` alongside it or the work restarts.
- `mgr:manual-approve` — never self-merge; the operator approves.

A hold parked under `mgr:in-flight` silently eats a build slot — keep the two straight. When a `research` issue closes, check what it unblocked before letting the board run: work that resolves by a human act (a signup, an account, an approval) can look ready to the filter while being nobody's diff — give it `mgr:hold` and a comment instead.

## Where panes live

Every issue session's pane, and every operation session's pane, is a **tab inside that
repo's own configured herdr `workspace`** — the same workspace id named in the board's
`workspace` field (or, for a project board, that repo's `repos[]` entry's `workspace`
field). No issue or operation ever gets a separate, per-worktree herdr workspace of its
own.

Git worktree isolation — a separate checkout and branch per issue, so concurrent issues
never collide in the primary checkout — is a plain on-disk `git worktree` checkout only,
with no herdr-level counterpart. This automation deliberately never calls herdr's own
`worktree create`: that command always creates a second, separate herdr workspace as a
side effect of making the checkout, which is exactly the bug that produced empty,
agent-less orphan workspaces in the past.

The watcher validates at startup that a configured `workspace` really is that repo's own
primary workspace — its checkout matches `path`, and it is not itself a linked-worktree
workspace — so a misconfigured value now fails loudly at startup instead of silently
landing panes somewhere unrelated.

**Workspace lifetime.** A herdr workspace is destroyed when its **last tab closes**, so a board's
`workspace` is expected to be **long-lived** — it must outlive every session that lands in it. A
workspace whose only tabs are transient (an issue tab, a research or `op:` tab) self-destructs the
moment the last one is closed, and the board's configured id is then dead. Keep one permanent
**anchor tab** in each repo's workspace so its tab count never reaches zero; the watcher names the
ones it creates `<board> workspace anchor - do not close`, and neither sweep ever closes it.
Closing an `op:` tab (step 6) or a research tab that happens to be the workspace's last tab is the
normal way this breaks.

If it does break, the watcher recovers rather than looping: on a `workspace_not_found` from `herdr
tab create` it re-resolves that repo's own primary workspace from `path`, or re-opens `path` as a
new workspace (with an anchor tab) if none is live, rewrites its in-memory repo map, and retries
the launch — then reports the fault once per (board, repo), naming the board and the exact config
field (`workspace`, or `repos[<k>].workspace`) and the new id. **The config file is never
rewritten**: the runtime id is authoritative only for that run, and startup validation still exits
2 on the stale id, so update the field when you see that report. If no workspace can be
established either, the watcher reports one of two things depending on why. When herdr confirms
the configured workspace is gone but a replacement could not be resolved this cycle — a transient
herdr/git hiccup — it reports that as a transient issue, not a config fault, and expects the next
cycle's local retry to resolve it on its own. When it is a genuine, repeatable fault — usually
`path` itself is gone or no longer resolves to a usable checkout — it reports a config fault
instead, naming the field to update. Either way the claim is released and the watcher **stops
claiming issues for that repo entirely** (rather than claiming and releasing one every cycle); it
retries locally each cycle and resumes on its own once the path has a usable workspace.

## Running several boards

Use one watcher process for several boards when: independent boards run over one repo, one project board spans repos, or several repos need boards in the same session. Pass `--config <file>` instead of the positional args and mode; the file is loaded and validated once at startup and never re-read — changing it means restarting the watcher.

```json
{
  "poll_seconds": 30,
  "report_agent": "board",
  "boards": [
    { "name": "harness", "kind": "repo", "repo": "owner/repo",
      "path": "/abs/checkout", "workspace": "ws_abc",
      "concurrency": 3, "mode": "supervised" },
    { "name": "platform", "kind": "project", "owner": "me", "number": 7,
      "concurrency": 2, "mode": "auto",
      "repos": [ { "repo": "owner/repo", "path": "/abs/checkout", "workspace": "ws_abc" } ] }
  ]
}
```

`poll_seconds` (optional, default 30) and `report_agent` (optional) are watcher-wide. Each board needs a unique `name` matching `^[a-z0-9-]+$` (it labels that board's tabs and agents), a `kind` (`repo` or `project`), and `concurrency` — required, never defaulted, per board. `mode` defaults `supervised`. A `repo` board additionally needs `repo` (`owner/repo`), `path`, `workspace`. A `project` board needs `owner`, `number`, and a non-empty `repos` array of `{repo, path, workspace}` — one entry per repo the board spans.

Startup validation exits 2 naming the offending board and field for: a missing/duplicate `name`, a missing `concurrency`, a `path` that doesn't exist or isn't a git checkout, an `origin` remote that doesn't match the configured `repo`, a `workspace` that isn't that repo's own primary herdr workspace (its checkout must equal `path`, and it must not itself be a linked-worktree workspace — not merely "a workspace that exists"; a `workspace` that exists at startup but is destroyed later is handled at runtime, not here — see "Workspace lifetime"), or a `project` board with no `repos`. Concurrency is strictly per board — there is no global ceiling; the sum across boards is your total load, and the startup log line reports that sum plus an estimated gh requests/hour.

## 4. Start the watcher

`<WORKSPACE_ID>` is the target repo's own primary herdr workspace — the workspace whose checkout is `<project dir>` itself, matching `path`/`workspace` in "Running several boards" below — never this board-watcher session's own workspace, and never `herdr pane current`. If `<project dir>` isn't already open as its own herdr workspace, open it as one first (see "Where panes live" above), then use that workspace's id. Start the bundled script as a persistent background process — do not hand-roll the poll loop inline. One board — this form is unchanged, not deprecated:

```
hub op="start" name="<project>-work-the-board" application="bash" \
  args=["<skill-dir>/scripts/watch.sh", "<WORKSPACE_ID>", "<CONCURRENCY>", "30", "board", "<MODE>", "--project", "<owner>/<number>"] \
  cwd="<project dir>" restart="on-failure" persist=true
```

`<skill-dir>` is this skill's absolute directory (given in the invocation prompt's "Skill directory" footer). Args are `<WORKSPACE_ID>` — the target repo's own primary workspace, per above, never this board-watcher session's own workspace — `<CONCURRENCY>`, poll seconds, the report target (pass `board`, see "Reporting"), and the mode (`supervised`/`auto`; unknown mode exits 2). Append the trailing `--project <owner>/<number>` pair only in project mode. A malformed `--project` value, a board missing the Status field or its `Todo`/`In progress` options, or a token without the `project` scope exits 2 at startup with the reason.

Several boards: write the config file (see "Running several boards" above) and pass it instead — `--config` cannot combine with positional args or `--project`:

```
hub op="start" name="<project>-work-the-board" application="bash" \
  args=["<skill-dir>/scripts/watch.sh", "--config", "<CONFIG_FILE>"] \
  cwd="<project dir>" restart="on-failure" persist=true
```

Either way, check the log right after starting (`hub`, `op: "logs"`): it prints the total concurrency across boards and an estimated gh requests/hour, and warns when that estimate is above 3000/h — if it does, raise `poll_seconds` in the config (or the positional poll-seconds argument) and restart.

Switching mode restarts the watcher and only affects sessions launched afterwards; steer already-running ones directly (`herdr agent prompt <issue-N> "..."`) if needed.

The script does, every cycle:

1. Counts open issues labeled `mgr:in-flight` — capacity in use.
2. Selects the **ready** issues: open, carrying none of `mgr:in-flight`, `mgr:hold`, `research`, and every `Blocked by: #N` reference either absent or itself closed. Ordered `priority:high` first, then lowest issue number.
3. Looks for work that already exists for that issue — an open PR whose head branch carries the number or whose title/body *closes* it, else a remote branch carrying the number — so the session **adopts** it instead of opening a second branch and PR. A bare `#N` mention is not enough: PRs routinely name related issues.
4. For each free slot, takes the next ready issue, **claims it** with `mgr:in-flight`, opens a tab inside the repo's own configured `workspace` (a plain on-disk `git worktree` checkout backs the session — it has no herdr workspace of its own), starts an `omp` agent, renames the tab `<board>/issue-<N>: <title>`, and hands it the issue number plus adoption instructions. The agent is named `<board>-issue-<N>` (herdr agent names are global, so the board name keeps two boards' issue #12 apart). A session that fails to come up has its tab closed and its claim **released**.
5. Sweeps finished tabs (below).
6. Sleeps, then repeats.

In project mode, swap Status for labels in 1–2 and 4: capacity = open `In progress` cards, ready = open `Todo` items (same `research` and `Blocked by` rules, same ordering), claim/release = Status edits, and a closed issue's card is reconciled to `Done`. Labels are never read or written for board state.

With several boards, each is serviced inside its own error boundary: one board's failure never stops the others. A fetch failure is distinguished from a genuinely empty board, so an expired token or dead remote reports as an error instead of looking idle — three consecutive failed cycles produce one latched `[<board>] degraded: <reason>` report, and the next success emits one `[<board>] recovered`; once a board is well past that (five straight failures) it is only serviced every tenth cycle, so a broken board stops burning rate limit.

A project board's items are dispatched into their own mapped repo's `path` and `workspace` — a project board spanning repos runs each item where that repo's `repos` entry points. An item whose repo isn't in the board's `repos` map is skipped and left untouched in `Todo`, reported once per (board, repo) — never held on the operator's behalf. The same issue sitting on two boards at once (a label board and a project board, say) is claimed only once: whichever board sees it in flight or claims it first wins, the other skips it quietly.

**The watcher owns selection and claiming.** Do not spawn a generic session and let it find its own issue — that spawns a throwaway agent and tab every cycle when nothing is ready. Pre-claiming also closes the double-pick race between concurrent launches.

`watch.sh` encodes several `herdr`/`jq` response-shape and shell-quoting pitfalls — see its comments. Reuse it verbatim rather than re-deriving them.

**Reporting.** Every report line is prefixed `[<board-name>]`, so with several boards in one process you can tell them apart — `[harness] issue #42 launched...`. With a report target, the watcher prompts that agent on material changes only: an issue launched (number, title, tab) and claimed; an issue that **left flight** — landed, closed, or claim dropped elsewhere — with its new state (the only way a session landing its own issue becomes visible from here); any launch failure, and whether the claim was released; a ready issue skipped without being claimed because its own `<board>-issue-<N>` agent is still live from a session that has not exited yet — reported once until that agent's name is freed, never every cycle; a board's configured `workspace` having been destroyed at runtime — reported once per (board, repo) as a **config fault** naming the field, either recovered-for-this-run with the new id or unrecoverable with the exact fix, never repeated every cycle; a board going degraded or recovering (above); and an issue that has been in flight for over an hour, repeated on every further hour boundary it crosses (state for this lives in a hidden marker comment on the issue itself, not a local file, so it survives a watcher restart). Idle cycles are never reported. Sends are fire-and-forget, never `--wait`, so a busy board session cannot stall the loop. Startup and stop each send one consolidated, unprefixed message covering every configured board, not one message per board. Relay these to the operator; they are the board's audit trail.

**Landing is the operator's call.** The handed-over prompt tells a supervised session to stop after pushing and leave `gh pr ready`, merging, closing and worktree removal to explicit instruction given **in the issue's own tab** (`land`, `ready`, `done`) — the board session never sees it. So a `left flight (issue is now CLOSED)` report is normally the operator landing it directly; before raising an alarm, check the owning session's transcript (`herdr agent list` gives its `agent_session` path) rather than the board:

```bash
grep -n '"attribution":"user"' <session>.jsonl   # what the operator actually typed, and when
```

**Tab lifecycle.** On `done` the session removes its own worktree, then closes its own tab. The watcher's sweep is only a backstop for a session that dies, is killed, or exits before teardown: it closes a `<board>/issue-<N>:` tab once that issue is CLOSED and its worktree is gone, every cycle. More working tabs than `mgr:in-flight` issues is normal, not a leak — a session outlives its claim (it drops the label and closes the issue on landing, then may keep working, e.g. a post-land review, until it exits). If that same issue reopens while that session's `<board>-issue-<N>` agent is still live, the watcher skips it without claiming it — reported once, not relaunched every cycle. Normally no action is needed: it self-heals and the issue launches automatically once that session exits and frees the name. If that session has already finished, close its tab to free the name now; on a multi-repo project board the name can instead belong to a different repo's issue sharing the same board+number, in which case free it without disturbing that other session via `herdr agent rename <name> --clear`. Neither sweep here frees it for you on its own, since `sweep_finished_tabs` requires the issue closed and `sweep_orphan_worktrees` (below) only reaps stray linked-worktree registrations, never a tab sitting in a repo's own primary workspace. A second sweep, `sweep_orphan_worktrees`, reaps stray herdr workspaces left over from the old per-worktree-workspace mechanism (or created by hand or another tool): a workspace belonging to one of the board's own repos, whose issue number it derives from its checkout path's basename (falling back to a tab label inside it) matching an issue-number pattern — never from the workspace's own display label — with no live agent in any of its panes, whose issue is not currently in flight, is removed (`herdr worktree remove`, never forced — a dirty checkout is reported once and left alone instead — then `herdr workspace close`). Before any of that, a local-only, no-GitHub-calls guard checks the candidate's checkout for an upstream tracking branch and for commits not yet pushed to it; a candidate that has no upstream, or has unpushed commits, or on which the check itself fails, is left untouched, not reaped, and reported once (`found orphan workspace … but its checkout has no upstream or has commits not yet pushed`). That guard protects unpushed work, not a deliberately-parked-but-clean checkout: a worktree that is clean and fully pushed is still reaped even if its issue is open but not in flight (e.g. carrying `mgr:hold`) — don't be surprised when a held issue's worktree disappears; the work itself is safe because it is on the remote branch. It never touches a repo's own configured `workspace`, a worktree whose issue is still in flight, or another board's repos, and it makes no GitHub calls. This only reaps a bare `issue-<N>:`-labeled tab when that tab lives inside one of those old linked-worktree workspaces — the whole workspace, tab included, is what gets removed. A bare `issue-<N>:`-labeled tab sitting inside a repo's own PRIMARY workspace — whether a genuine leftover from before the naming change, or the normal, ongoing shape a standalone `next-issue` session still produces for a manually-moved pane — lives in that repo's own configured `workspace`, so `sweep_orphan_worktrees` structurally excludes it, and it doesn't match `sweep_finished_tabs`' `<board>/issue-<N>:` pattern either: it is covered by **neither** sweep, and still needs a manual `herdr tab rename`/close pass once its issue leaves flight. This sweep and self-teardown both cover issue tabs only — an `op:` tab is neither swept nor self-closing; see Op-tab teardown in step 6, which is this session's own job.

## 5. Verify one cycle

Follow the log (`hub`, `op: "logs"`, `follow: true`) for one cycle. Each line reads `in-flight=<n> free=<n> ready=<n> launching=<n>`. Sanity-check it against the board:

- `ready=0` while the board plainly has an unblocked, unclaimed issue means the readiness filter is broken. Cross-check with `gh issue list --state open --json number,labels,body`.
- `launching>0` should be followed by an `issue #N launched:` line; confirm a real agent came up, not just a tab:

```bash
herdr pane get <PANE_ID>   # agent_status should be "working" or "idle", not "unknown"
```

A pane stuck at `agent_status: "unknown"` with no session file means the launch failed in a way the script didn't catch; stop the watcher and re-check the `herdr` CLI surface (`herdr tab create --help`, `herdr agent start --help`) before restarting it.

Also confirm nesting: `herdr pane get <PANE_ID>` (or `herdr workspace get <id>`) should report the launched issue's pane `workspace_id` equal to the workspace the board is currently using for that repo — normally the configured `workspace`, or the id named in a workspace-recovery report if one has fired (see "Workspace lifetime") — it landed as a tab in the repo's own workspace, not somewhere else.

`ready=0` with everything genuinely blocked or claimed is the correct steady state: report that as-is rather than forcing work.

## 6. Route other operator input

`ready`, `land`, and `done` are never typed here — those go in the issue's own tab, and the
board session never sees them. Anything else the operator sends this tab, at any point
while the watcher runs, is either issue-worthy work, research, or a one-off operation.
Classify it before acting; never run it in this pane:

| Input | Meaning | Action |
|---|---|---|
| Bug, feature, or anything else that resolves as a diff | Issue-worthy | Run `new-issue` inline, right now, in this session |
| Resolves by a human deciding, approving, or registering something — not a diff | Research | Run `new-issue` the same way; it lands with the `research` label, so the watcher leaves it alone |
| No diff to land at all — restart a local deployment, run a DB query, tail a log, poke a running service | Operation | Launch a fresh session for it (below); never run it here |

Filing an issue or research item this way is bookkeeping, not work — it costs this
session nothing and needs no session of its own.

**Several boards configured:** file against the board the request plainly belongs to (by
repo, path, or explicit operator naming); ask which board only when it is genuinely
ambiguous. `new-issue`'s own `gh` commands run unscoped, so `cd` into that board's `path`
(or pass `--repo <owner/repo>`) before running them.

**Launching an operation session.** Running the operation here blocks this pane and stalls
report delivery from the watcher, so hand it off the same way the watcher hands off an
issue — a visible tab and agent the operator can watch and steer, not a hidden `task`
subagent:

```bash
herdr tab create --workspace <WORKSPACE_ID> --cwd <BOARD_PATH> --no-focus
herdr agent start <name> --kind omp --pane <PANE_ID>
herdr tab rename <TAB_ID> "op: <short description>"
herdr agent prompt <name> "<operator's request, verbatim>"
```

`<WORKSPACE_ID>` is the same per-board/per-repo `workspace` config value `launch_issue`
uses for that repo — never this board-watcher session's own workspace — so the op tab
lands beside issue tabs in the repo's own workspace. It is available directly from the
board config file (or, for the single positional-board form, is the workspace argument
passed to `watch.sh` at startup). `<BOARD_PATH>` is the target repo's checkout — `path`
in the config for a `repo` board, the mapped repo's `repos[]` entry for a `project`
board, or `<project dir>` for a single positional board — the same directory issue tabs
already land in via `--cwd "$item_path"`, so the operation pane opens in the repo it
operates on instead of wherever this board session happens to be running.

Name it so it can't collide with an issue agent (`<board>-issue-<N>`) — e.g.
`<board>-op-<short-slug>`. Do not `--wait` on the prompt; that would block this session's
own loop. Relay whatever the operation session reports back to the operator when it
arrives.

**Op-tab teardown.** This session owns closing the op tab — nothing else ever will, since
the watcher's sweep only matches `<board>/issue-<N>:` and an `op:` label can never satisfy
that. Note `<name>`/`<TAB_ID>`/`<PANE_ID>` together at launch so an op still open can be
found again later (`herdr tab list` / `herdr agent list`, filtered by the
`<board>-op-<slug>` name from above).

After relaying a report, check `herdr pane get <PANE_ID>`:

| `agent_status` | Meaning | Action |
|---|---|---|
| `idle` or `done` | Operation finished | `herdr tab close <TAB_ID>` now |
| `working` | Still running; this report may be interim | Leave the tab open; re-check on this session's next wake |
| `blocked` | Waiting on the operator for an answer | Leave the tab open; relay what it needs and re-check after the operator responds |
| `unknown`, no session file | Op agent died or never came up | Orphaned — close it, and say so once |

A report is routinely sent from inside the op agent's own turn, so `agent_status` can still
read `working` the instant after you relay it — that is not proof the operation is done.
Re-check every op tab this rule left open on the next report, the next operator turn, and
unconditionally at Stop (below); close it the first time its status reads `idle`/`done` —
or orphaned, per the table above.
Never close a tab that reads `working` or `blocked` — `blocked` means the operator hasn't
answered it yet, not that the operation is finished.
Before closing an op tab, note whether it is the **last** tab in that repo's workspace (`herdr
workspace list` reports `tab_count`): closing it destroys the workspace, which is what the anchor
tab in "Where panes live" exists to prevent.

## 7. Stop

Stop the background process (`hub`, `op: "stop"`) and report the last observed in-flight count. Sessions close their own tabs on `done`, so an issue tab still open after stopping either belongs to a session still finishing its own work, or — if its agent never started (`agent_status: "unknown"`, no session file, per `herdr tab list`) — is a genuine orphan, safe to close by hand with `herdr tab close <TAB_ID>`. Any `op:` tab still open at this point is this session's own to close (see Op-tab teardown in step 6): close it now unless `herdr pane get <PANE_ID>` still reads `working` or `blocked` — name any tab left open for that reason as still running in the stop report so the operator knows it's theirs to steer or close from here.
