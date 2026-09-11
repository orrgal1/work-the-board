# work-the-board

Five agent skills for running a GitHub issue board with autonomous coding sessions.
Built for [omp](https://github.com/orrgal1/oh-my-pi) and [herdr](https://herdr.dev),
which supply the agent runtime and the tab/worktree workspace manager.

| Skill | Use |
|---|---|
| `new-issue` | File one request as a deduped issue, placed in its dependency lane. |
| `next-issue` | Own one issue end to end: worktree, draft PR, implement, land on command. |
| `work-the-board` | Keep N issues in flight: poll, claim, hand each to a `next-issue` session. |
| `plan-on-tier` | Plan with a subagent pinned to an explicit provider/model tier (1-3). |
| `review-on-tier` | Review with a subagent pinned to an explicit provider/model tier (1-3). |

## How it fits together

`work-the-board` runs `work-the-board/scripts/watch.sh` as a background process. Every
cycle it counts issues labelled `mgr:in-flight`, selects the ready ones, claims a free
slot's worth, and launches a session per issue that follows `next-issue`. Sessions plan
and review through `plan-on-tier` / `review-on-tier`.

**Concurrency is yours to set and is never defaulted.** Say it when you start the board
— "work the board, 3 at a time" — or the session asks before launching anything. It
becomes the watcher's ceiling: each cycle it counts open issues labelled
`mgr:in-flight`, launches at most `ceiling - in-flight` sessions, and launches nothing
when the board is full or nothing is ready. Only `mgr:in-flight` consumes a slot, so a
stale claim costs you capacity until it is cleared. Changing the limit means restarting
the watcher; already-running sessions keep going.

Two modes: `supervised` stops each session after it pushes, leaving `ready`/`land`/`done`
to the operator in that issue's own tab; `auto` lets a session plan, implement, review,
and land on its own. `mgr:manual-approve` blocks a self-merge in either mode.

## Labels

- `mgr:in-flight` — a builder owns it. The only label that counts against concurrency.
- `mgr:hold` — nobody should build it yet. Blocks pickup, costs no slot.
- `research` — resolves by a human deciding or approving something, not by a diff. Never auto-picked.
- `mgr:awaiting-approval` — PR open, work done, operator's call.
- `mgr:manual-approve` — never self-merge.

## Install

Symlink each skill directory into your agent's skills directory:

```bash
git clone https://github.com/orrgal1/work-the-board ~/code/work-the-board
for s in new-issue next-issue work-the-board plan-on-tier review-on-tier; do
  ln -s ~/code/work-the-board/$s ~/.omp/agent/skills/$s
done
```

Requires `gh` (authenticated), `jq`, `git`, and `herdr` on `PATH`.
