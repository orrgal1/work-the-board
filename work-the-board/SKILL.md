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

**Operation lifecycle.** Running the operation here blocks report delivery, so give it a
visible tab and agent in the mapped repo workspace. `scripts/ops.py` is the authoritative
registry and cleanup controller; shell status and an `op:` label are not lifecycle state.

The rule is simple: track tabs the board owns, wait for explicit completion, deliver the
result, respect a keep-open request, then check and close. Idle alone never means done.
Use one durable database shared by the watcher, this board session, and every operation:

```bash
OPS_PY="<absolute-skill-dir>/scripts/ops.py"
STATE_DB="${WORK_THE_BOARD_OPERATION_STATE_DB:-${XDG_STATE_HOME:-$HOME/.local/state}/work-the-board/operations.sqlite3}"
REPORT_TARGET="board"
OPS=(python3 "$OPS_PY" --state-db "$STATE_DB" --report-recipient "$REPORT_TARGET")
```

Both paths must be absolute. The watcher uses the same default and accepts the same
`WORK_THE_BOARD_OPERATION_STATE_DB` override. The SQLite registry survives watcher,
workspace, and board-session restarts; never put it in `/tmp`, an installed skill tree, or
a disposable issue worktree.

Allocate a unique opaque `<OPERATION_ID>` and start at generation `0`. A generation is one
business operation and is final after completion. Additional work waits for that generation's
safe close, then launches under a new generation; do not steer new work into a completed
retained tab.

**Launch and register.** Resolve `<BOARD>`, `<REPO>`, `<BOARD_PATH>`, and
`<WORKSPACE_ID>` from the watcher's current board mapping. For a project board,
`<REPO>` selects its `repos[]` row. Use the runtime workspace id from a recovery report,
when present, rather than the stale config value.

```bash
"${OPS[@]}" launch-operation "$OPERATION_ID" 0 \
  --board "$BOARD" --repo "$REPO" --workspace "$WORKSPACE_ID" \
  --cwd "$BOARD_PATH" --agent "$AGENT_NAME" \
  --label "op: <short description>" \
  --prompt "<operator request verbatim, plus the lifecycle handoff below>" \
  --evidence "durable launch intents reconciled before business prompt"
```

`launch-operation` reserves the generation and full request before any side effect.
A process-held local lock prevents two invocations from launching the same operation.
After a restart, a started agent can be recovered through its saved pane/terminal and
live session identity. A lost create response or uncertain business prompt requires
manual inspection; a mutable tab label or missing agent name never authorizes replay.
Only a confirmed pre-commit rejection is automatically retryable. Registration must
succeed before the business prompt. Resolve uncertain launches explicitly before starting
another operation; do not blindly repeat their business request under a new id.

The root pane is `.result.root_pane.pane_id`. Registration must succeed before the
business prompt is sent; otherwise no operation owns that tab. Agent names remain outside
the issue namespace, for example `<board>-op-<slug>`. Operation agents inherit the current
OMP default unless the operator explicitly requests another model. Do not wait on the
business prompt from this board pane.

The handoff includes the exact `OPS_PY`, `STATE_DB`, `REPORT_TARGET`, operation id, and
generation. It requires the operation agent to publish every business transition through
`ops.py`:

```bash
"${OPS[@]}" transition "$OPERATION_ID" 0 waiting_user \
  --evidence "waiting for operator answer" --transition-id "<stable-transition-id>"
"${OPS[@]}" report "$OPERATION_ID" 0 "<REPORT_ID>" "<interim body>" --submit
"${OPS[@]}" transition "$OPERATION_ID" 0 working \
  --evidence "operator answered" --transition-id "<stable-transition-id>"
"${OPS[@]}" complete "$OPERATION_ID" 0 "<FINAL_REPORT_ID>" "<final body>" \
  --evidence "requested operation completed"
# Or, on a real failure:
"${OPS[@]}" fail "$OPERATION_ID" 0 "<FAILURE_REPORT_ID>" "<failure and recovery body>" \
  --evidence "operation failed"
```

`working` and `waiting_user` are explicit business states. `idle`, `done`, `failed`,
`dead`, or an authentication error from the terminal is only runtime evidence: it never
means the requested task completed. A dead or failed runtime needs an explicit durable
`fail` report describing recovery or retirement; never convert it to successful completion
and never replay its business action automatically.

**Report delivery and acknowledgment.** `complete` and `fail` atomically persist a final
report before attempting delivery. The watcher retries reports that remain `pending`; a
successful transport is only `submitted`. The board session relays the received `body`
to the operator, then acknowledges the exact stable id, digest, generation, and recipient:

```bash
"${OPS[@]}" ack "$OPERATION_ID" 0 "$REPORT_ID" \
  --digest "$REPORT_DIGEST" --recipient "$REPORT_TARGET" \
  --evidence "relayed verbatim to the operator"
```

Never acknowledge before relay, from terminal status, or with a reconstructed digest.
If no report target is configured, the report remains durable and pending; it is not
implicitly delivered. Reusing the same report id/content is idempotent. A different body,
generation, digest, or recipient is rejected. The transport cannot make the relay/ack
crash gap exactly once, so use the stable report id to recognize a replay and acknowledge
only after confirming the operator received that exact report.

**Retention.** Retention is an explicit bounded lease, not “the agent is still alive.”
Acquire it before completing when a reviewer or operator must keep the tab:

```bash
"${OPS[@]}" retain "$OPERATION_ID" 0 "$LEASE_ID" "$HOLDER" "$REASON" --ttl 86400
"${OPS[@]}" release "$OPERATION_ID" 0 "$LEASE_ID" \
  --evidence "holder released retention"
```

Use 24 hours by default and never grant more than 7 days (`604800` seconds) per explicit
lease. Renewal uses a new lease id. Release addresses the exact lease and generation.
Expiry only removes retention; it does not complete work or acknowledge a report.
`working` and `waiting_user` remain protected after lease expiry.

**Cleanup ownership and failure retirement.** Once per watcher cycle, outside every
board's GitHub failure/backoff boundary, `watch.sh` runs:

```bash
python3 "$OPS_PY" --state-db "$STATE_DB" \
  --report-recipient "$REPORT_TARGET" \
  --anchor "<WORKSPACE_ID>=<ANCHOR_TAB_ID>" tick
```

Anchor arguments are rebuilt from the watcher's current runtime repo/workspace mappings;
missing or ambiguous anchors disable cleanup for that workspace. `ops.py` closes only a
registered `completed` generation whose final report is acknowledged and whose retention
has released or expired, or a failed generation explicitly moved to `retiring`. It also
requires a fresh exact workspace/tab/pane/terminal/session/agent binding, one pane in the
tab, a quiescent runtime, a separate live anchor, and more than one workspace tab. Missing,
changed, working, blocked, or unreadable state fails closed. Legacy/user-created `op:`
tabs are unregistered and never swept.

After those checks, the controller calls ordinary `herdr tab close <TAB_ID>`. No new
Herdr API is required. Another actor could change the tab between inspection and close;
this small check/close race is an accepted tradeoff for the single-owner board.
Uncertain state is left open for inspection rather than guessed.

A failed operation remains visible after its failure report is acknowledged. Retire it
only with explicit operator authorization:

```bash
"${OPS[@]}" retire "$OPERATION_ID" 0 --evidence "operator authorized failed-operation retirement"
```

The next tick applies the same identity, quiescence, anchor, and last-tab guards. Cleanup
only closes the operation tab. It never closes a workspace, stops a process tree, removes
a worktree or data, or replays an operation. A deployment/updater intended to survive the
tab must already run under an independent persistent supervisor; shell backgrounding is
not proof of independence.

## 7. Stop

Stop the background process (`hub`, `op: "stop"`) and report the last observed in-flight count. Sessions close their own tabs on `done`, so an issue tab still open after stopping either belongs to a session still finishing its own work, or — if its agent never started (`agent_status: "unknown"`, no session file, per `herdr tab list`) — is a genuine orphan, safe to close by hand with `herdr tab close <TAB_ID>`. Do not status-sweep operation tabs at stop. Their lifecycle remains durable in `STATE_DB`; `working`, `waiting_user`, `failed`, retained, unacknowledged, and safety-deferred operations stay open, and eligible cleanup resumes on the next watcher tick. Use `"${OPS[@]}" list` to report their explicit states.
