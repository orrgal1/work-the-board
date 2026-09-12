# work-the-board

Five agent skills, plus the tier agent definitions they spawn, for running a GitHub
issue board with autonomous coding sessions. Built for [omp](https://github.com/orrgal1/oh-my-pi)
and [herdr](https://herdr.dev), which supply the agent runtime and the tab/worktree
workspace manager.

| Skill | Use |
|---|---|
| `new-issue` | File one request as a deduped issue, placed in its dependency lane. |
| `next-issue` | Own one issue end to end: worktree, draft PR, implement, land on command. |
| `work-the-board` | Keep N issues in flight: poll, claim, hand each to a `next-issue` session, and route anything else the operator sends the board tab instead of doing it there. |
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

**Several boards, one process.** Pass `--config <file>` instead of the positional args to run several boards — independent repos, a Projects v2 board that spans repos, or a mix — from one watcher. Concurrency is set per board with no global cap; a project board's `repos` array lets it dispatch each item into that repo's own checkout and its own configured `workspace` (never the board-watcher session's own workspace). A board's `workspace` must be that repo's own primary herdr workspace — its checkout equal to `path`, and not itself a linked-worktree workspace — which the watcher now validates at startup. Minimal two-board example:

```json
{ "boards": [
  { "name": "harness", "kind": "repo", "repo": "owner/repo",
    "path": "/abs/checkout", "workspace": "ws_abc", "concurrency": 3 },
  { "name": "platform", "kind": "project", "owner": "me", "number": 7,
    "concurrency": 2,
    "repos": [ { "repo": "owner/repo", "path": "/abs/checkout", "workspace": "ws_abc" } ] }
] }
```

Two modes: `supervised` stops each session after it pushes, leaving `ready`/`land`/`done`
to the operator in that issue's own tab; `auto` lets a session plan, implement, review,
and land on its own. `mgr:manual-approve` blocks a self-merge in either mode.

## Labels

- `mgr:in-flight` — a builder owns it. The only label that counts against concurrency.
- `mgr:hold` — nobody should build it yet. Blocks pickup, costs no slot.
- `research` — resolves by a human deciding or approving something, not by a diff. Never auto-picked.
- `mgr:awaiting-approval` — PR open, work done, operator's call.
- `mgr:manual-approve` — never self-merge.

## Layout

- `new-issue/`, `next-issue/`, `work-the-board/`, `plan-on-tier/`, `review-on-tier/` —
  skills, installed into `~/.omp/agent/skills/`.
- `agents/` — the six tier agent definitions `plan-tier1..3` and `review-tier1..3` that
  `plan-on-tier` and `review-on-tier` spawn, installed into `~/.omp/agent/agents/`.

## Install

One block installs both halves — the skills and the tier agents:

```bash
git clone https://github.com/orrgal1/work-the-board ~/code/work-the-board
for s in new-issue next-issue work-the-board plan-on-tier review-on-tier; do
  ln -s ~/code/work-the-board/$s ~/.omp/agent/skills/$s
done
for a in plan-tier1 plan-tier2 plan-tier3 review-tier1 review-tier2 review-tier3; do
  ln -s ~/code/work-the-board/agents/$a.md ~/.omp/agent/agents/$a.md
done
```

Requires `gh` (authenticated), `jq`, `git`, and `herdr` on `PATH`. `plan-on-tier` and
`review-on-tier` resolve tiers 1-3 from `@tier1`/`@tier2`/`@tier3` in your `modelRoles`
(`~/.omp/agent/config.yml`); if your config doesn't define those roles, add them first —
the tier agents will fail to resolve a model without them.
