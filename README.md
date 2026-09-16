# work-the-board

Five skills for turning GitHub issues into isolated, reviewable changes:

- `new-issue`: dedupe and place new work.
- `next-issue`: own one issue through worktree, draft PR, review, landing, and cleanup.
- `work-the-board`: keep a configured number of issue sessions in flight.
- `plan-on-tier` and `review-on-tier`: run genuine internal children at explicit tiers.

## Runtime model

One `watch.sh` process may service one or several configured boards. It selects ready
issues, claims capacity, and launches one visible coordinator session per issue in the
repository's primary Herdr workspace. Each coordinator creates a plain Git worktree;
there is no per-issue Herdr workspace, helper process, or second coordinator.

Each newly created coordinator receives exactly one initial handoff, including a fresh
coordinator created for absent-owner recovery. The watcher never injects later prompts,
send-keys, or composer input into an existing owner or the board; that coordinator keeps
completion responsibility. Explicit communication requested by a human operator is not
routine watcher automation.

Tiered planning and review are internal task children. Provider-local mappings must be
loaded before dispatch and runtime metadata must prove the selected role/provider/model.
A routing failure is reported; it is never bypassed with a headless/background OMP
process, helper tab, provider switch, or coordinator restart.

Repo boards use `mgr:in-flight` for capacity and `mgr:hold` for genuine holds. Project
boards use Status (`Todo`, `In progress`, `Blocked`, `Done`). `research`,
`mgr:manual-approve`, and `Blocked by: #N` apply to both.

## Installation

Install or symlink each skill directory into the harness skill directory, install the six
agent role files from `agents/`, and ensure Bash, `jq`, `git`, `gh`, and `herdr` are on
`PATH`. Configure provider-local plan/review role mappings in one OMP config and give its
absolute path to the watcher so every issue coordinator loads it at initial launch.
The single-board interface is `watch.sh <workspace> <concurrency> [poll_seconds]
--mode supervised|auto [--project owner/number]`; pass `--mode` explicitly. Old
four/five-positional report-target forms and any multi-board `report_agent` field,
including null or empty values, fail closed before external calls. Start the watcher
through the harness process manager as documented in `work-the-board/SKILL.md`; do not
hand-roll a polling loop. Observe it passively through process status and watcher logs.

## Updating a running board

A merged repository change is not active until the board performs a controlled update.
The board must stop its identified watcher to pause new admissions, leave existing issue
sessions alone, verify the primary checkout has no unknown local work, fast-forward it to
`origin/main`, refresh installed skill/agent links or copies, restart the same watcher
from its retained launch specification, and observe one real cycle. Report the loaded
revision and cycle counts. Never pull over user work or update the live watcher from an
issue worktree.
