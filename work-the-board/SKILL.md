---
name: work-the-board
description: "Keep a fixed number of GitHub issues in flight by launching one next-issue session per ready issue."
---

# Work The Board

This session coordinates; it does not implement issues. Run one watcher process, which
selects and claims work before launching one visible `next-issue` coordinator per issue.
Never replace issue sessions with generic tasks or extra coordinator processes.

## Board contract

Concurrency and mode are explicit per board. `supervised` sessions stop after verified
implementation; the operator later sends `ready`, `land`, or `done` in the issue tab.
`auto` sessions plan when needed, implement, review every diff, and land unless
`mgr:manual-approve` requires a ready PR and operator approval.

Repo mode uses:

- `mgr:in-flight`: claimed work and the only capacity-consuming label.
- `mgr:hold`: genuine external/operator wait; comment why; consumes no slot.
- `research`: a human decision/action rather than a diff; never auto-picked.
- `mgr:manual-approve`: autonomous sessions must not merge.

Project mode uses Status: `Todo`, `In progress`, `Blocked`, and `Done`. The watcher is the
only Status writer. `research`, `mgr:manual-approve`, and `Blocked by: #N` still apply.

Ready issues are open, not held/research, and have closed `Blocked by:` dependencies.
Order `priority:high` first, then issue number. The watcher claims before launch and
releases a fresh claim if launch fails.

## Start safely

Before starting, reconcile every existing in-flight claim against live issue tabs,
branches, and PRs. Keep legitimate work; close landed issues; convert real waits to holds;
release only claims proven stale. Never blanket-clear labels or Status.

Every configured `path` must be the repository's cleanly identified primary checkout;
every `workspace` must be that checkout's primary Herdr workspace, not a linked worktree.
Issue coordinators create plain Git worktrees but remain tabs in this workspace. Keep an
anchor tab so Herdr does not destroy an otherwise empty workspace.

Auto mode also requires one absolute readable OMP config containing executable
provider-local mappings for every plan/review tier it may dispatch. Supply it as
`WORK_THE_BOARD_AGENT_CONFIG` for the positional form or top-level `agent_config` in a
multi-board config. The watcher passes `--config` on the initial issue-coordinator start,
including recovery launches; invalid or absent auto-mode configuration fails at startup.

For one repo board:

```text
hub start name=<repo>-work-the-board application=bash
  args=[<skill-dir>/scripts/watch.sh,<workspace>,<concurrency>,30,--mode,<mode>]
  env={WORK_THE_BOARD_AGENT_CONFIG:<absolute-agent-config>}
  cwd=<repo-path> restart=on-failure persist=true
```

Append `--project <owner>/<number>` for project mode. The positional interface is
`watch.sh <workspace> <concurrency> [poll_seconds] --mode supervised|auto
[--project owner/number]`; `--mode` must be explicit and at most three positional
arguments are accepted. Old four/five-positional report-target forms fail before any
external call. For multiple boards, use `watch.sh --config <absolute-file>` with unique
lowercase-dash names, top-level `agent_config`, and per-board `kind`, `concurrency`,
`mode`, repository path, and workspace. A `report_agent` key is invalid even when null
or empty. Project boards provide `owner`, `number`, and a non-empty `repos` mapping.
The watcher validates paths, origins, workspaces, board fields, auto-mode agent
configuration, and configuration shape before its first cycle.

Use the harness process manager; never hand-roll or shell-background the watcher. Check
startup logs and observe one cycle: `in-flight=<n> free=<n> ready=<n> launching=<n>`.
Every launch must produce a real named agent in the configured workspace. Empty/blocked
boards correctly launch nothing.

## Issue lifecycle

The watcher gives a newly created coordinator exactly one initial handoff stating the
issue, adoption state, mode, and review/landing contract. Absent-owner recovery creates
a fresh coordinator and likewise hands off exactly once. Planning/review remain genuine
internal children of that issue coordinator through `plan-on-tier` and `review-on-tier`.
The board never starts an OMP planner/reviewer, helper tab, operation wrapper, dedicated
process, or headless/background fallback. Provider-local role configuration must already
be loaded; routing failure is surfaced.

After that initial handoff, the watcher never injects prompts, send-keys, or composer
input into an existing issue owner or the board. Existing coordinators retain completion
responsibility. The watcher reconciles live ownership and closes only finished issue tabs
whose issue is closed and worktree is gone. Ambiguous ownership or destructive cleanup
fails closed. Degraded/recovered conditions are emitted only to passive watcher logs;
operators observe those logs and process status through the harness process manager.
A missing workspace may be re-resolved for the running process, but configuration remains
a startup contract and must be corrected before restart.

## Other operator input

- Named issue planning/review/investigation: send it to that issue coordinator.
- Work producing a diff: run `new-issue` inline so the watcher can schedule it.
- Human decision/action: file as `research` or hold it.
- Basic answer, status, or bookkeeping: handle inline.
- Operational commands with no diff are outside this board system; do not invent an
  operation coordinator, state store, tab lifecycle, or daemon for them.

Explicit communication requested by a human operator, including a supervised `ready`,
`land`, or `done`, is operator input to the coordinator; it is not routine watcher
automation.

## Controlled update and activation

A merge does not update a running board. After the issue lands, the board owns activation:

1. Record the running watcher name/spec, installed skill locations, current primary HEAD,
   and live issue sessions. Stop that identified watcher to pause new admissions; do not
   stop or move issue sessions.
2. Fetch `origin/main`. If primary status contains unknown work, stop and report it.
   Otherwise fast-forward only: `git merge --ff-only origin/main`. Never reset or clean.
3. Refresh installed skill and agent symlinks/copies from the updated primary. Update the
   retained launch environment or board JSON with the absolute provider-local
   `agent_config`; preserve concurrency, mode, and workspaces. Confirm the installed
   `watch.sh` and tier skills resolve to the merged revision and the config contains every
   tier auto mode may request.
4. Restart that same identified watcher with the corrected retained specification. A
   startup config failure leaves admissions paused; fix the specification rather than
   bypassing it. Observe startup and one real cycle, confirm concurrency/mode and existing
   claims are unchanged, and confirm any newly launched issue gets exactly one visible
   coordinator whose initial start includes the config.
5. Report loaded revision, cycle counts, preserved sessions, and any failure. Overall board
   completion occurs only after this observed activation cycle.

Do not perform this update from an issue worktree or while its PR is unmerged.

## Stop

Stop only the identified watcher process and report its last counts. Leave live issue
sessions alone; their coordinators own landing and cleanup. Close an issue tab manually
only when its issue is closed, worktree is gone, and no live agent owns it.
