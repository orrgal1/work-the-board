#!/usr/bin/env bash
# work-the-board watcher: keeps each configured board's <concurrency> issues
# in flight by selecting, claiming, and handing out ready issues to
# next-issue sessions.
#
# Usage: watch.sh <workspace_id> <concurrency> [poll_seconds] [report_agent] [supervised|auto] [--project <owner>/<number>]
#        watch.sh --config <file>
#
#   mode: supervised (default) — sessions stop after pushing; the operator
#         instructs ready/land/done per issue, in that issue's own tab.
#         auto — sessions plan (tier 2, if complex; tier 3 for
#         mission-critical or high-risk work such as auth/permissions, money,
#         data loss or irreversible operations, schema/migrations, or the
#         board's own control plane), implement, then run a mandatory review
#         at the plan tier for rounds 1-2 (tier 2 if no plan ran), escalating
#         to tier 3 from round 3 on, before landing. mgr:manual-approve still
#         gates the merge.
#
#   --project <owner>/<number>: project mode, for multiple independent boards
#         over one repo or one board spanning repos. The named GitHub
#         Projects v2 board's Status single-select replaces the mgr:*
#         capacity labels as the state machine: Todo = ready pool,
#         In progress = in flight (the only status counting against
#         concurrency), Blocked = hold (no pickup, no slot), Done =
#         finished. The watcher is the only Status writer; a human dragging
#         a card is authoritative - the watcher observes and reports the
#         move, never fights it. research and mgr:manual-approve stay issue
#         properties and apply identically in both modes.
#
#   --config <file>: one watcher, several boards. The JSON file lists repo
#         (label-based) boards, Projects v2 boards, or a mix, each with its
#         own checkout path, workspace, concurrency, and mode:
#
#           { "poll_seconds": 30, "report_agent": "board",
#             "boards": [
#               { "name": "harness", "kind": "repo", "repo": "owner/repo",
#                 "path": "/abs/checkout", "workspace": "ws_abc",
#                 "concurrency": 3, "mode": "supervised" },
#               { "name": "platform", "kind": "project", "owner": "me",
#                 "number": 7, "concurrency": 2, "mode": "auto",
#                 "repos": [ { "repo": "owner/repo", "path": "/abs/checkout",
#                              "workspace": "ws_abc" } ] } ] }
#
#         Concurrency is strictly per board: each board computes its own
#         free = concurrency - inflight and fills its own slots from its own
#         ready list. There is no global ceiling, no cross-board arbitration,
#         no fairness rotation — total machine load is the operator's sum
#         across the file, printed once at startup so it is a visible number.
#         The file is loaded and validated once at startup and never re-read;
#         changing it means restarting the watcher.
#
#         The positional form is synthesized into an equivalent one-board
#         config (repo from `gh repo view`, path from the cwd — exactly the
#         repo those calls implied before), so both invocations run the SAME
#         downstream code path; there is no legacy branch.
#
# Every cycle, for each configured board:
#   1. Counts open issues labeled mgr:in-flight (capacity used).
#   2. Selects the READY issues: open, carrying none of mgr:in-flight,
#      mgr:hold, or research, and every "Blocked by: #N" reference
#      closed/absent. Ordered priority:high first, then lowest number.
#   3. For each free slot, takes the next ready issue, CLAIMS it with
#      mgr:in-flight, opens a tab, starts an omp agent, and hands it that
#      specific issue number. Nothing ready means nothing launched.
#   4. Sweeps tabs whose issue is closed and whose worktree is gone.
# Then sleeps once, and repeats.
#
# The watcher owns selection and claiming so a session is only ever spawned
# when there is real work for it: spawning a session to let it discover
# "nothing ready" burns a throwaway agent and a tab every single cycle.
# A claim is released again if the session fails to come up.
set -uo pipefail

USAGE="usage: watch.sh <workspace_id> <concurrency> [poll_seconds] [report_agent] [supervised|auto] [--project <owner>/<number>]
       watch.sh --config <file>"

# Positionals stay positional; --project is a trailing flag, so every
# existing invocation parses exactly as before. --config excludes both.
POS_KIND=repo
PROJECT_OWNER=""
PROJECT_NUMBER=""
WORKSPACE=""
CONCURRENCY=""
POLL_SECONDS=30
REPORT_TARGET=""
MODE=supervised
CONFIG_FILE=""

# Operation lifecycle state must outlive this checkout and the watcher process.
# A single absolute override lets the board session and operation agents address
# the same durable registry without coupling it to an installed skill path.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || {
  echo "watch.sh: cannot resolve its script directory" >&2
  exit 2
}
OPS_PY="$SCRIPT_DIR/ops.py"
if [ -n "${WORK_THE_BOARD_OPERATION_STATE_DB:-}" ]; then
  OPERATION_STATE_DB=$WORK_THE_BOARD_OPERATION_STATE_DB
elif [ -n "${XDG_STATE_HOME:-}" ]; then
  OPERATION_STATE_DB="$XDG_STATE_HOME/work-the-board/operations.sqlite3"
elif [ -n "${HOME:-}" ]; then
  OPERATION_STATE_DB="$HOME/.local/state/work-the-board/operations.sqlite3"
else
  echo "watch.sh: HOME or XDG_STATE_HOME is required for durable operation state" >&2
  exit 2
fi
case "$OPERATION_STATE_DB" in
  /*) ;;
  *) echo "watch.sh: WORK_THE_BOARD_OPERATION_STATE_DB must be an absolute path" >&2; exit 2 ;;
esac
[ -r "$OPS_PY" ] || { echo "watch.sh: operation controller is not readable: $OPS_PY" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "watch.sh: python3 is required for operation lifecycle maintenance" >&2; exit 2; }
npos=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:-}"
      if [ -z "$CONFIG_FILE" ]; then
        echo "--config needs a file argument" >&2
        echo "$USAGE" >&2
        exit 2
      fi
      shift 2
      ;;
    --project)
      spec="${2:-}"
      PROJECT_OWNER="${spec%%/*}"
      PROJECT_NUMBER="${spec##*/}"
      case "$spec" in
        */*) ;;
        *) PROJECT_OWNER="" ;;
      esac
      case "$PROJECT_NUMBER" in
        ''|*[!0-9]*) PROJECT_OWNER="" ;;
      esac
      if [ -z "$PROJECT_OWNER" ]; then
        echo "bad --project value: '$spec' (want <owner>/<number>)" >&2
        echo "$USAGE" >&2
        exit 2
      fi
      POS_KIND=project
      shift 2
      ;;
    *)
      npos=$((npos + 1))
      case "$npos" in
        1) WORKSPACE="$1" ;;
        2) CONCURRENCY="$1" ;;
        3) POLL_SECONDS="$1" ;;
        4) REPORT_TARGET="$1" ;;
        5) MODE="$1" ;;
        *) echo "$USAGE" >&2; exit 2 ;;
      esac
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Per-board scalars. bash 3.2 has no associative arrays, so board state lives
# in eval-indexed scalars BOARD_<i>_<FIELD>, addressed through these two
# helpers (no fork, no subshell: bv leaves its result in $bvv).
#
# eval safety: <i> is always a numeric loop counter, <FIELD> a literal
# identifier at every call site, and the VALUE reaches eval only as the
# unexpanded positional \$3 — it is assigned, never re-parsed as shell. On
# top of that, free text (issue titles, bodies, raw error output) never
# enters a BOARD_ scalar at all: titles live in plain TSV strings
# (inflight_data, ready_list) and function arguments only; the persisted
# per-board state is issue numbers, ISO timestamps, and gh-issued ids.
# ---------------------------------------------------------------------------
bv() { eval "bvv=\${BOARD_$1_$2-}"; }
bset() { eval "BOARD_$1_$2=\$3"; }

# Resolves an item's repo (owner/repo) to board <i>'s local checkout path or
# workspace through BOARD_<i>_REPOMAP ("nwo<TAB>path<TAB>workspace" lines).
# rc 1 when the repo is not in the map — the caller decides whether that is
# a skip (project items of unmapped repos) or a bug (a launch for a repo the
# backend itself admitted).
repo_path() { # <i> <nwo>
  local m
  bv "$1" REPOMAP
  m=$(awk -F'\t' -v r="$2" '$1 == r { print $2; exit }' <<<"$bvv")
  [ -n "$m" ] || return 1
  printf '%s\n' "$m"
}
repo_workspace() { # <i> <nwo>
  local m
  bv "$1" REPOMAP
  m=$(awk -F'\t' -v r="$2" '$1 == r { print $3; exit }' <<<"$bvv")
  [ -n "$m" ] || return 1
  printf '%s\n' "$m"
}

# Rewrites board <i>'s REPOMAP row for <nwo> with a new workspace id. This is
# the ONE place the runtime workspace id diverges from the config: the config
# value is authoritative at startup (WSCHECK), this map is authoritative for
# dispatch during the run. Keeps CUR_REPOMAP (the copy board_ctx_load took)
# and BOARD_<i>_WS in step, so nothing in the process can read a stale id.
repo_set_workspace() {   # <i> <nwo> <new_ws> <old_ws>
  local m
  bv "$1" REPOMAP
  m=$(awk -F'\t' -v OFS='\t' -v r="$2" -v w="$3" '$1 == r { $3 = w } { print }' <<<"$bvv")
  bset "$1" REPOMAP "$m"
  [ "$1" = "${CUR_IDX:-}" ] && CUR_REPOMAP=$m
  bv "$1" WS
  if [ "$bvv" = "${4-}" ]; then       # <4> = the old id being replaced
    bset "$1" WS "$3"
    [ "$1" = "${CUR_IDX:-}" ] && CUR_WS=$3
  fi
}

# The config field name WSCHECK would print for this repo: "workspace" for a
# repo board, "repos[<k>].workspace" for a project board. REPOMAP rows are
# built from .repos in array order (see the bset at the board-init loop), the
# same order WSCHECK's `repos | to_entries` uses, so row N is index N-1 and
# the operator sees byte-identical field names at startup and at runtime.
repo_ws_field() {        # <i> <nwo>
  local k
  bv "$1" KIND
  if [ "$bvv" = "repo" ]; then printf 'workspace\n'; return 0; fi
  bv "$1" REPOMAP
  k=$(awk -F'\t' -v r="$2" '$1 == r { print NR - 1; exit }' <<<"$bvv")
  printf 'repos[%s].workspace\n' "${k:-?}"
}

# skip_once <nwo>: rc 0 exactly once per (board, repo) — records
# "<board>\x01<nwo>" in the current board's SKIP set and refuses the second
# time. The unmapped-repo notice goes through this so it fires on state
# entry only, like the other latched reports.
skip_once() {
  local sep set
  sep=$'\x01'
  bv "$CUR_IDX" SKIP; set=$bvv
  if grep -qxF "$CUR_NAME$sep$1" <<<"$set"; then return 1; fi
  bset "$CUR_IDX" SKIP "$(printf '%s\n%s%s%s' "$set" "$CUR_NAME" "$sep" "$1")"
}

# Repos whose herdr workspace is gone AND could not be re-established, one
# "<nwo>" line per repo in BOARD_<i>_WSDEAD. Unlike SKIP this is clearable:
# the launch gate retries the (local, GitHub-free) recovery each cycle, so
# reopening the workspace by hand or restoring the checkout self-heals
# without a watcher restart.
ws_dead()       { local s; bv "$1" WSDEAD; s=$bvv; [ -n "$2" ] && grep -qxF "$2" <<<"$s"; }
ws_dead_mark()  { local s; bv "$1" WSDEAD; s=$bvv; ws_dead "$1" "$2" || bset "$1" WSDEAD "$(printf '%s\n%s' "$s" "$2")"; }
ws_dead_clear() { local s; bv "$1" WSDEAD; s=$bvv; bset "$1" WSDEAD "$(grep -vxF "$2" <<<"$s")"; }

# An issue whose own launch-target agent name (built the same way
# launch_issue builds "$CUR_NAME-issue-$num") is still a live herdr agent
# from a session that has not exited yet: "<nwo>#<num>" lines in
# BOARD_<i>_AGENTBUSY. Unlike SKIP this is clearable (like ws_dead*): once
# a later cycle's name check no longer finds that agent live, the launch
# loop clears the mark so a genuinely new occurrence of the same issue
# number still gets its own report instead of being silently swallowed by
# a stale latch (#20).
agent_busy()       { local s; bv "$1" AGENTBUSY; s=$bvv; [ -n "$2" ] && grep -qxF "$2" <<<"$s"; }
agent_busy_mark()  { local s; bv "$1" AGENTBUSY; s=$bvv; agent_busy "$1" "$2" || bset "$1" AGENTBUSY "$(printf '%s\n%s' "$s" "$2")"; }
agent_busy_clear() { local s; bv "$1" AGENTBUSY; s=$bvv; bset "$1" AGENTBUSY "$(grep -vxF "$2" <<<"$s")"; }

# ---------------------------------------------------------------------------
# Config: --config file, or the positional form synthesized into the exact
# equivalent one-board config. Parsed and validated in ONE jq pass that
# emits TSV rows: ERR (validation failure), CFG (globals), BOARD (one per
# board, in file order), RCHECK (one per repo/path pair to verify against
# the filesystem), WSCHECK (one per board/workspace pair to verify against
# herdr's live workspace list). Any ERR row aborts with exit 2 before the
# first cycle — a bad path discovered lazily is a silently parked board.
# ---------------------------------------------------------------------------
CONFIG_VALIDATE='
def istr: type == "string";
def nzstr: istr and (length > 0);
def clean: nzstr and ((test("[[:cntrl:]]|\\\\")) | not);
def posint: type == "number" and . == floor and . >= 1;
def isrepo: clean and test("^[^/]+/[^/]+$");
def bname($i): if (.name | nzstr) then .name else "#\($i)" end;
def berrs($i):
  if type != "object" then [["ERR", "#\($i)", "board", "must be an object"]]
  else bname($i) as $b |
    ([ (if (.name | nzstr) | not then ["name", "required"]
        elif ((.name | test("^[a-z0-9-]+$")) | not) then ["name", "must match ^[a-z0-9-]+$"]
        else empty end),
       (if (.kind == "repo" or .kind == "project") | not
        then ["kind", "must be repo or project"] else empty end),
       (if (.concurrency | posint) | not
        then ["concurrency", "required, a positive integer"] else empty end),
       (if (.mode == null or .mode == "supervised" or .mode == "auto") | not
        then ["mode", "must be supervised or auto"] else empty end) ]
     + (if .kind == "repo" then
          [ (if (.repo | isrepo) | not then ["repo", "required, owner/repo"] else empty end),
            (if (.path | clean) | not then ["path", "required"] else empty end),
            (if (.workspace | clean) | not then ["workspace", "required"] else empty end) ]
        elif .kind == "project" then
          [ (if (.owner | clean) | not then ["owner", "required"] else empty end),
            (if (.number | posint) | not then ["number", "required, a positive integer"] else empty end) ]
          + (if ((.repos | type) == "array" and (.repos | length) > 0) | not
             then [["repos", "required, a non-empty array of {repo, path, workspace}"]]
             else [ .repos | to_entries[] | . as $r |
                    (if ($r.value | type) != "object"
                     then ["repos[\($r.key)]", "must be an object"] else empty end),
                    (if ($r.value | type) == "object" and (($r.value.repo | isrepo) | not)
                     then ["repos[\($r.key)].repo", "required, owner/repo"] else empty end),
                    (if ($r.value | type) == "object" and (($r.value.path | clean) | not)
                     then ["repos[\($r.key)].path", "required"] else empty end),
                    (if ($r.value | type) == "object" and (($r.value.workspace | clean) | not)
                     then ["repos[\($r.key)].workspace", "required"] else empty end) ]
             end)
        else [] end)
     | map(["ERR", $b] + .))
  end;
. as $cfg
| (if ($cfg | type) != "object" then [["ERR", "-", "config", "top level must be a JSON object"]]
   else
     (if ($cfg.poll_seconds != null) and (($cfg.poll_seconds | posint) | not)
      then [["ERR", "-", "poll_seconds", "must be a positive integer"]] else [] end)
     + (if ($cfg.report_agent != null)
           and ((($cfg.report_agent | istr)
                 and (($cfg.report_agent == "") or ($cfg.report_agent | clean))) | not)
        then [["ERR", "-", "report_agent", "must be a string without control characters or backslashes"]] else [] end)
     + (if (($cfg.boards | type) != "array") or (($cfg.boards | length) == 0)
        then [["ERR", "-", "boards", "required, a non-empty array"]]
        else ([ $cfg.boards | to_entries[] | . as $e | ($e.value | berrs($e.key)) ] | add // [])
             + ($cfg.boards | map(select(type == "object") | .name) | map(select(type == "string")) | group_by(.)
                | map(select(length > 1) | ["ERR", .[0], "name", "duplicate board name"]))
        end)
   end) as $errs
| if ($errs | length) > 0 then $errs[] | @tsv
  else
    (["CFG", (($cfg.poll_seconds // 30) | floor), ($cfg.report_agent // "")] | @tsv),
    ($cfg.boards[]
      | (if .kind == "repo"
         then ["BOARD", .name, "repo", .repo, .path, .workspace, (.concurrency | floor),
               (.mode // "supervised"), "", ""]
         else ["BOARD", .name, "project", .repos[0].repo, .repos[0].path, .repos[0].workspace,
               (.concurrency | floor), (.mode // "supervised"), .owner, (.number | floor)]
         end) | @tsv),
    ($cfg.boards[] | .name as $b
      | (if .kind == "repo" then {repo: .repo, path: .path} else (.repos[] | {repo: .repo, path: .path}) end)
      | ["RCHECK", $b, .repo, .path] | @tsv),
    ($cfg.boards[] | .name as $b
      | (if .kind == "repo" then [{field: "workspace", ws: .workspace, path: .path}]
         else [ .repos | to_entries[] | {field: "repos[\(.key)].workspace", ws: .value.workspace, path: .value.path} ]
         end)[]
      | ["WSCHECK", $b, .field, .ws, .path] | @tsv)
  end
'

if [ -n "$CONFIG_FILE" ]; then
  if [ "$npos" -gt 0 ] || [ "$POS_KIND" = "project" ]; then
    echo "watch.sh: --config cannot be combined with positional arguments or --project" >&2
    echo "$USAGE" >&2
    exit 2
  fi
  if [ ! -r "$CONFIG_FILE" ]; then
    echo "watch.sh: config: cannot read $CONFIG_FILE" >&2
    exit 2
  fi
  CONFIG_JSON=$(cat "$CONFIG_FILE")
  if ! jq -e . >/dev/null 2>&1 <<<"$CONFIG_JSON"; then
    echo "watch.sh: config: $CONFIG_FILE is not valid JSON" >&2
    exit 2
  fi
else
  if [ -z "$WORKSPACE" ] || [ -z "$CONCURRENCY" ]; then
    echo "$USAGE" >&2
    exit 2
  fi
  case "$MODE" in
    supervised|auto) ;;
    *) echo "unknown mode: $MODE" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
  # The positional form implied "this checkout": resolve the repo those bare
  # gh calls used to act on, and pin the cwd as the board's path, so the
  # synthesized config reproduces exactly today's behaviour.
  POS_NWO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
  if [ -z "$POS_NWO" ]; then
    echo "watch.sh: cannot resolve this checkout's repository (gh repo view failed)" >&2
    exit 2
  fi
  CONFIG_JSON=$(jq -n \
    --arg ws "$WORKSPACE" --arg conc "$CONCURRENCY" --arg poll "$POLL_SECONDS" \
    --arg report "$REPORT_TARGET" --arg mode "$MODE" --arg kind "$POS_KIND" \
    --arg repo "$POS_NWO" --arg path "$PWD" \
    --arg owner "$PROJECT_OWNER" --arg number "$PROJECT_NUMBER" '
    { poll_seconds: ($poll | tonumber? // $poll),
      boards: [
        ( { name: "board", kind: $kind,
            concurrency: ($conc | tonumber? // $conc), mode: $mode }
          + (if $kind == "repo"
             then { repo: $repo, path: $path, workspace: $ws }
             else { owner: $owner, number: ($number | tonumber? // $number),
                    repos: [ { repo: $repo, path: $path, workspace: $ws } ] }
             end) ) ] }
    + (if $report == "" then {} else { report_agent: $report } end)')
fi

rows=$(jq -r "$CONFIG_VALIDATE" <<<"$CONFIG_JSON" 2>&1) || {
  echo "watch.sh: config: validation failed: $rows" >&2
  exit 2
}

if grep -q '^ERR' <<<"$rows"; then
  while IFS=$'\t' read -r _tag b f m; do
    [ -z "$f" ] && continue
    if [ "$b" = "-" ]; then
      echo "watch.sh: config: $f: $m" >&2
    else
      echo "watch.sh: config: board $b: $f: $m" >&2
    fi
  done <<<"$(grep '^ERR' <<<"$rows")"
  exit 2
fi

IFS=$'\t' read -r _tag POLL_SECONDS REPORT_TARGET <<<"$(grep '^CFG' <<<"$rows")"

# Memoizes `git -C <path> rev-parse --show-toplevel` per checkout path across
# every call this process makes (cache lives in ORPHAN_ROOT_CACHE, "<path>\t
# <root>" lines) — RCHECK already proved each mapped path is a git checkout
# at startup and the config cannot change without a restart, so one lookup
# per path for the whole run is enough. rc 1 if the path is not resolvable.
ORPHAN_ROOT_CACHE=""
repo_root_for() { # <path>
  local p="$1" hit root
  hit=$(awk -F'\t' -v p="$p" '$1==p{print $2; exit}' <<<"$ORPHAN_ROOT_CACHE")
  if [ -n "$hit" ]; then printf '%s\n' "$hit"; return 0; fi
  root=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$root" ] || return 1
  ORPHAN_ROOT_CACHE=$(printf '%s\n%s\t%s' "$ORPHAN_ROOT_CACHE" "$p" "$root")
  printf '%s\n' "$root"
}

# Filesystem-level validation, still before the first cycle: every checkout
# path must exist and be a git repo whose origin remote is the configured
# repo. Wrong path or wrong remote at cycle time would not error loudly — it
# would quietly run another repo's worktree and branch checks.
while IFS=$'\t' read -r _tag b r p; do
  [ "$_tag" = "RCHECK" ] || continue
  if [ ! -d "$p" ]; then
    echo "watch.sh: config: board $b: path: does not exist: $p" >&2
    exit 2
  fi
  if ! git -C "$p" rev-parse --git-dir >/dev/null 2>&1; then
    echo "watch.sh: config: board $b: path: not a git checkout: $p" >&2
    exit 2
  fi
  origin_url=$(git -C "$p" remote get-url origin 2>/dev/null)
  if [ -z "$origin_url" ]; then
    echo "watch.sh: config: board $b: repo: $p has no origin remote" >&2
    exit 2
  fi
  # Normalize the origin URL down to its trailing owner/repo: handles
  # https://host/owner/repo(.git), ssh://git@host/owner/repo, and the
  # scp-style git@host:owner/repo.
  o="${origin_url%/}"
  o="${o%.git}"
  o_repo="${o##*/}"
  o_rest="${o%/*}"
  o_owner="${o_rest##*/}"
  o_owner="${o_owner##*:}"
  if [ "$o_owner/$o_repo" != "$r" ]; then
    echo "watch.sh: config: board $b: repo: $r does not match the origin remote of $p ($origin_url)" >&2
    exit 2
  fi
done <<<"$rows"

# Workspace validation, still before the first cycle: every board's
# workspace must be a live herdr workspace, AND it must be that board's own
# repo's PRIMARY workspace — not merely any workspace that happens to
# exist. A stale id would otherwise pass a bare existence check and then die
# forever in launch_issue's `herdr tab create --workspace` with
# workspace_not_found, releasing the claim and repeating every cycle; a live
# but WRONG id (e.g. the board-watcher session's own workspace, or some other
# repo's workspace, pasted in by mistake) would instead pass silently and
# land every issue's tab somewhere that is not this repo's own nesting home
# — exactly the gap this repo owns closing (nothing previously tied
# `workspace` to `path`). A workspace counts as the repo's own primary
# workspace only when herdr reports its `worktree.checkout_path` resolving
# (via `repo_root_for`'s `git rev-parse --show-toplevel`, the same
# canonicalization the orphan sweep relies on) to the same git toplevel as
# the board's configured `path` AND `worktree.is_linked_worktree` false —
# comparing the raw strings would wrongly fail a trailing slash, a relative
# path, or a symlinked path even though the workspace is correct. A
# workspace with a mismatched checkout_path, or one that is itself a linked
# (git-worktree-backed) workspace, fails immediately — except a completely
# ABSENT `worktree` field is retried a few times first: herdr has been
# observed to report `worktree: null` transiently for a workspace that is,
# moments later, correctly populated, so an absent field alone gets a
# bounded second look rather than an immediate exit 2.
ws_list_out=$(herdr workspace list 2>/dev/null)
ws_list_rc=$?
if [ "$ws_list_rc" -ne 0 ] || ! jq -e . >/dev/null 2>&1 <<<"$ws_list_out"; then
  ws_list_err=$(herdr workspace list 2>&1 >/dev/null)
  echo "watch.sh: cannot list herdr workspaces: ${ws_list_err:-$ws_list_out}" >&2
  exit 2
fi
live_ws=$(jq -r '.result.workspaces[]?.workspace_id? // empty' <<<"$ws_list_out")

# tsv: <has_worktree 0|1> <checkout_path> <is_linked_worktree "true"|"false"|"">
ws_worktree_fields() { # <ws_list_json> <ws_id>
  jq -r --arg id "$2" '
    (.result.workspaces[]? | select(.workspace_id == $id)) as $e
    | ($e.worktree // null) as $wt
    | [ (if $wt == null then "0" else "1" end),
        ($wt.checkout_path // ""),
        (if ($wt // {} | has("is_linked_worktree")) then ($wt.is_linked_worktree | tostring) else "" end) ]
    | @tsv' <<<"$1"
}

# The runtime counterpart of the WSCHECK loop below: given a checkout path,
# prints the id of a live herdr workspace that IS that path's own primary
# workspace, by the same rule WSCHECK enforces at startup (worktree present,
# checkout_path resolving to the same git toplevel via repo_root_for, and
# is_linked_worktree false). rc 0 with the id printed means a match; rc 1
# means no such workspace exists (safe to create one); rc 2 means it could
# NOT be determined (repo_root_for failed on $path itself, herdr workspace
# list failed, or its output was not valid JSON) - callers MUST treat rc 2
# as "do not know", never as "none exists".
#
# Kept separate from WSCHECK on purpose: WSCHECK answers "is THIS configured
# id right, and if not, exactly how is it wrong" (with its own transient
# worktree:null retry and its own exit-2 messages); this answers "which id is
# right for this path, if any". Same predicate, two questions - if the rule
# changes, change both. Nothing here weakens or repeats the startup check.
#
# Deliberate simplification, not an oversight: unlike WSCHECK, this does NOT
# retry a transiently-null worktree field (herdr has been observed to report
# worktree: null for a workspace that is moments later correct). WSCHECK's
# own retry loop is untouched and stays the belt this does not duplicate; a
# workspace whose worktree is transiently null here just isn't matched this
# call, and the pre-claim gate calls this again next cycle anyway.
#
# A per-CANDIDATE repo_root_for failure (some OTHER live workspace's own
# checkout no longer resolving - operator deleted or moved that clone) is
# deliberately just skipped (#19 review round 4, MAJOR-1), not treated as
# "could not determine": returning 2 there let one unrelated stale
# workspace anywhere in `workspace list` disable recovery for every repo
# on the board. Safe to fall through to "no match" for $path specifically:
# ensure_repo_workspace's caller then tries `herdr worktree open`, which is
# idempotent and ADOPTS (never forks) if a live workspace for $path really
# exists (#19 review round 3, B2) - the fork risk this originally guarded
# against no longer exists.
resolve_primary_workspace() {   # <path>
  local out want id checkout linked root
  want=$(repo_root_for "$1") || return 2
  out=$(herdr workspace list 2>/dev/null) || return 2
  jq -e . >/dev/null 2>&1 <<<"$out" || return 2
  while IFS=$'\t' read -r id checkout linked; do
    [ -z "$id" ] && continue
    [ "$linked" = "false" ] || continue
    root=$(repo_root_for "$checkout") || continue
    [ "$root" = "$want" ] || continue
    printf '%s\n' "$id"
    return 0
  done <<<"$(jq -r '.result.workspaces[]? | select((.worktree? // null) != null)
      | [.workspace_id, (.worktree.checkout_path // ""),
         ((.worktree.is_linked_worktree // false) | tostring)] | @tsv' <<<"$out")"
  return 1
}

while IFS=$'\t' read -r _tag b field ws path; do
  [ "$_tag" = "WSCHECK" ] || continue
  if ! grep -qxF -- "$ws" <<<"$live_ws"; then
    echo "watch.sh: config: board $b: $field: does not exist: $ws" >&2
    exit 2
  fi

  cur_ws_out="$ws_list_out"
  attempt=1
  while :; do
    IFS=$'\t' read -r ws_has_wt ws_checkout ws_linked <<<"$(ws_worktree_fields "$cur_ws_out" "$ws")"
    [ "$ws_has_wt" = "1" ] && break
    [ "$attempt" -ge 3 ] && break
    sleep 1
    next_ws_out=$(herdr workspace list 2>/dev/null)
    jq -e . >/dev/null 2>&1 <<<"$next_ws_out" && cur_ws_out="$next_ws_out"
    attempt=$((attempt + 1))
  done

  if [ "$ws_has_wt" != "1" ]; then
    echo "watch.sh: config: board $b: $field: herdr could not confirm workspace $ws's worktree info after $attempt attempts (the worktree field stayed absent — this looks like transient herdr staleness rather than a wrong workspace; re-run watch.sh, or independently confirm $ws is $path's own primary workspace)" >&2
    exit 2
  fi

  path_root=$(repo_root_for "$path" 2>/dev/null)
  ws_checkout_root=""
  [ -n "$ws_checkout" ] && ws_checkout_root=$(repo_root_for "$ws_checkout" 2>/dev/null)
  if [ -z "$path_root" ] || [ -z "$ws_checkout_root" ] || [ "$ws_checkout_root" != "$path_root" ] || [ "$ws_linked" != "false" ]; then
    echo "watch.sh: config: board $b: $field: workspace $ws is not this repo's own primary workspace for path $path (need worktree.checkout_path to resolve to the same git toplevel as path, and worktree.is_linked_worktree == false; found checkout_path=${ws_checkout:-<none>}, is_linked_worktree=${ws_linked:-<none>}) — open $path as its own herdr workspace (not a git-worktree-linked one) and point $field at that workspace's id" >&2
    exit 2
  fi
done <<<"$rows"

NBOARDS=0
while IFS=$'\t' read -r _tag c_name c_kind c_repo c_path c_ws c_conc c_mode c_owner c_number; do
  [ "$_tag" = "BOARD" ] || continue
  i=$NBOARDS
  bset "$i" NAME "$c_name"
  bset "$i" KIND "$c_kind"
  bset "$i" REPO "$c_repo"
  bset "$i" PATH "$c_path"
  bset "$i" WS "$c_ws"
  bset "$i" CONC "$c_conc"
  bset "$i" MODE "$c_mode"
  bset "$i" OWNER "$c_owner"
  bset "$i" NUMBER "$c_number"
  # Filled in by resolve_project_board for kind=project.
  bset "$i" PROJECT_ID ""
  bset "$i" STATUS_FIELD_ID ""
  bset "$i" OPT_TODO ""
  bset "$i" OPT_IN_PROGRESS ""
  bset "$i" OPT_DONE ""
  # Mutable per-board state, saved/restored around each service_board call.
  bset "$i" PREV_INFLIGHT ""
  bset "$i" FIRST 1
  bset "$i" FLIGHT_CACHE ""
  bset "$i" FLIGHT_SEEN_DEPART ""
  bset "$i" DONE_SYNCED ""
  bset "$i" FAILS 0
  bset "$i" BACKOFF 0
  # Latched skip-once set for unmapped-repo notices: "<board>\x01<nwo>"
  # lines, appended when the skip is first reported (skip_once). Never
  # cleared — the config cannot change without a restart, and a restart
  # re-firing the notice once is acceptable.
  bset "$i" SKIP ""
  # Repos whose workspace died and could not be re-established (see ws_dead*):
  # gates claiming, cleared by the launch loop's own recovery retry.
  bset "$i" WSDEAD ""
  # Issues whose launch-target agent is still live from a prior session
  # (see agent_busy* above): gates claiming, cleared once that agent is
  # no longer live.
  bset "$i" AGENTBUSY ""
  # Cursor for the slow flight-age scan: epoch seconds before which the
  # scan does not run for this board. Seeded below with a per-board offset
  # so N boards' scans do not align into one API spike.
  bset "$i" AGE_NEXT 0
  # The board's full repo map, "nwo<TAB>path<TAB>workspace" lines: every
  # item is dispatched into ITS OWN repo's checkout and workspace through
  # repo_path/repo_workspace. An item whose repo is not in the map is
  # skipped (and reported once), never held and never Status-edited.
  bset "$i" REPOMAP "$(jq -r --argjson i "$i" \
    '.boards[$i] | (if .kind == "repo"
       then [{repo: .repo, path: .path, workspace: .workspace}]
       else .repos end)
     | .[] | [.repo, .path, .workspace] | @tsv' <<<"$CONFIG_JSON")"
  NBOARDS=$((NBOARDS + 1))
done <<<"$rows"

# Project boards resolve their ids once, at startup, so a bad board, a
# missing Status option, or a token without the project scope fails HERE
# with one clear message - not later, mid-cycle, once per issue.
status_option_id() { # <option name>; reads $fields_json from the caller
  jq -r --arg n "$1" '[.fields[]? | select(.name == "Status" and has("options"))][0].options[]? | select(.name == $n) | .id' <<<"$fields_json" 2>/dev/null
}

resolve_project_board() {
  local i="$1" name owner number fields_json sfid pid t p d
  bv "$i" NAME; name=$bvv
  bv "$i" OWNER; owner=$bvv
  bv "$i" NUMBER; number=$bvv
  fields_json=$(gh project field-list "$number" --owner "$owner" --format json 2>&1) || {
    if grep -q "missing required scopes" <<<"$fields_json"; then
      echo "watch.sh: board $name: gh token lacks the project scope; run: gh auth refresh -s project" >&2
    else
      echo "watch.sh: board $name: cannot read fields of project $owner/$number: $fields_json" >&2
    fi
    exit 2
  }
  sfid=$(jq -r '[.fields[]? | select(.name == "Status" and has("options"))][0].id // empty' <<<"$fields_json" 2>/dev/null)
  if [ -z "$sfid" ]; then
    echo "watch.sh: board $name: project $owner/$number has no single-select Status field" >&2
    exit 2
  fi
  t=$(status_option_id "Todo")
  p=$(status_option_id "In progress")
  d=$(status_option_id "Done")
  if [ -z "$t" ]; then
    echo "watch.sh: board $name: Status field of project $owner/$number has no Todo option" >&2
    exit 2
  fi
  if [ -z "$p" ]; then
    echo "watch.sh: board $name: Status field of project $owner/$number has no 'In progress' option" >&2
    exit 2
  fi
  pid=$(gh project view "$number" --owner "$owner" --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null)
  if [ -z "$pid" ]; then
    echo "watch.sh: board $name: cannot resolve the node id of project $owner/$number" >&2
    exit 2
  fi
  bset "$i" PROJECT_ID "$pid"
  bset "$i" STATUS_FIELD_ID "$sfid"
  bset "$i" OPT_TODO "$t"
  bset "$i" OPT_IN_PROGRESS "$p"
  bset "$i" OPT_DONE "$d"
}

b=0
while [ "$b" -lt "$NBOARDS" ]; do
  bv "$b" KIND
  if [ "$bvv" = "project" ]; then
    resolve_project_board "$b"
  fi
  b=$((b + 1))
done

# Stagger the boards' slow flight-age scans (each board scans only every
# AGE_SCAN_SECONDS — the notices are hourly, so scanning every poll bought
# nothing) across the window, so N boards do not fire their first-sight
# GitHub reads and marker writes in the same cycle.
AGE_SCAN_SECONDS=600
NOW_EPOCH=$(date -u +%s)
b=0
while [ "$b" -lt "$NBOARDS" ]; do
  bset "$b" AGE_NEXT $((NOW_EPOCH + b * AGE_SCAN_SECONDS / NBOARDS))
  b=$((b + 1))
done

# One per-board summary block, shared by the startup and stop reports: ONE
# consolidated message listing every board, not one message per board.
BOARDS_SUMMARY=""
b=0
while [ "$b" -lt "$NBOARDS" ]; do
  bv "$b" NAME; s_name=$bvv
  bv "$b" KIND; s_kind=$bvv
  bv "$b" MODE; s_mode=$bvv
  bv "$b" CONC; s_conc=$bvv
  BOARDS_SUMMARY=$(printf '%s\n[%s] kind=%s mode=%s concurrency=%s' \
    "$BOARDS_SUMMARY" "$s_name" "$s_kind" "$s_mode" "$s_conc")
  b=$((b + 1))
done

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# Fetch failures land their raw stderr here so the caller can log it. One
# file, created once, read only on the failure path.
ERRFILE=$(mktemp "${TMPDIR:-/tmp}/work-the-board-err.XXXXXX") || exit 1
# Mutation stderr is never emitted raw: GitHub CLI errors can contain URLs,
# headers, or other credentials. Only a bounded classification is reported.
MUTATION_ERRFILE=$(mktemp "${TMPDIR:-/tmp}/work-the-board-mutation-err.XXXXXX") || exit 1
trap 'rm -f "$ERRFILE" "$MUTATION_ERRFILE"' EXIT
BOARD_MUTATION_RC=0
BOARD_MUTATION_CLASS=""

# Reports a material change to the board session so the operator sees it without
# reading the log. Only state changes are reported — launches, failures, released
# claims — never idle cycles, or the board session gets woken every poll for
# nothing. Fire-and-forget: never --wait here, or a busy board session would
# stall the whole loop. report prefixes the current board's name so N boards'
# messages stay attributable in one operator session; report_raw carries the
# watcher-wide consolidated messages (startup/stop) only.
report_raw() {
  [ -n "$REPORT_TARGET" ] || return 0
  herdr agent prompt "$REPORT_TARGET" "board watcher: $1" >/dev/null 2>&1 || true
}
report() { report_raw "[$CUR_NAME] $1"; }

# Runs once per watcher cycle, outside every board's GitHub error boundary.
# ops.py owns report retries, lease expiry, identity checks, and tab cleanup;
# this wrapper supplies only watcher-wide delivery and the current runtime
# workspace anchors. A failed or ambiguous maintenance pass is log-only and
# can never change issue capacity, claims, selection, or either issue sweep.
operation_maintenance() {
  local tabs tabs_rc b bname map _repo _path ws anchor seen out rc material
  local -a ops_args
  ops_args=(--state-db "$OPERATION_STATE_DB")
  [ -n "$REPORT_TARGET" ] && ops_args+=(--report-recipient "$REPORT_TARGET")

  tabs=$(herdr tab list 2>/dev/null)
  tabs_rc=$?
  if [ "$tabs_rc" -ne 0 ] || ! jq -e . >/dev/null 2>&1 <<<"$tabs"; then
    log "operation maintenance: could not read live tabs for anchor discovery; cleanup will fail closed this cycle"
    tabs=""
  fi

  # BOARD_<i>_REPOMAP is authoritative after runtime workspace recovery.
  # Only one exact, standard anchor for a board/workspace pair is accepted.
  # Shared workspaces are emitted once; an absent or ambiguous anchor is
  # deliberately omitted so ops.py refuses cleanup rather than guessing.
  seen=""
  b=0
  while [ "$b" -lt "$NBOARDS" ]; do
    bv "$b" NAME; bname=$bvv
    bv "$b" REPOMAP; map=$bvv
    while IFS=$'\t' read -r _repo _path ws; do
      [ -n "$ws" ] || continue
      [ -n "$seen" ] && grep -qxF "$ws" <<<"$seen" && continue
      [ -n "$tabs" ] || continue
      anchor=$(jq -r --arg ws "$ws" --arg label "$bname workspace anchor - do not close" '
        [.result.tabs[]?
         | select(.workspace_id == $ws and (.label // "") == $label)
         | .tab_id]
        | if length == 1 then .[0] else empty end' <<<"$tabs" 2>/dev/null)
      [ -n "$anchor" ] || continue
      ops_args+=(--anchor "$ws=$anchor")
      seen=$(printf '%s\n%s' "$seen" "$ws")
    done <<<"$map"
    b=$((b + 1))
  done

  out=$(python3 "$OPS_PY" "${ops_args[@]}" tick 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "operation maintenance failed (will retry next cycle): $out"
    return 0
  fi
  material=$(jq -r '
    ((.expired_leases // 0) > 0)
    or ((.submitted_reports // []) | length > 0)
    or ((.report_errors // []) | length > 0)
    or ((.closed_operations // []) | length > 0)
    or ((.missing_operations // []) | length > 0)
    or ((.refused_operations // []) | length > 0)' <<<"$out" 2>/dev/null)
  [ "$material" = "true" ] && log "operation maintenance: $out"
  return 0
}

trap 'log "watcher stopping"; report_raw "stopped.$BOARDS_SUMMARY"; exit 0' TERM INT

# ---------------------------------------------------------------------------
# Board backends. The cycle body only calls board_load / board_inflight /
# board_ready / board_claim / board_release / board_finish; the CURRENT
# board's kind (CUR_KIND, loaded by board_ctx_load) picks the implementation.
# Repo mode is the original mgr:* label state machine, unchanged. Project
# mode reads and writes the board's Status single-select instead, and never
# reads or writes labels for board state.
#
# Fetchers distinguish ERROR from EMPTY: board_load and board_ready return
# rc 1 with empty output when the fetch itself failed (raw stderr left in
# $ERRFILE), and rc 0 with empty output only for a genuinely empty board.
# An expired token must surface as a failing board, never masquerade as an
# eternally idle one.
# ---------------------------------------------------------------------------

# Ready = open, carrying neither mgr:in-flight nor mgr:hold, and every
# "Blocked by: #N" reference closed or absent. Same rule next-issue applies,
# plus its ordering: operator priority (priority:high) first, then lowest
# issue number.
#
# mgr:in-flight and mgr:hold both block pickup, but only mgr:in-flight counts
# as capacity. A hold is an issue nobody should build yet — operator-owned, or
# waiting on an external answer — and parking it under mgr:in-flight silently
# caps concurrency below the configured ceiling while still reporting the slot
# as used.
#
# `research` issues are never auto-picked either. They resolve by a human
# deciding, approving, or registering something with an outside party — a
# lawyer's text, an accountant's answer, a Meta business account — so a builder
# handed one can only draft around the edges, and in autonomous mode it would
# go on to land a PR that represents a decision nobody made. Dispatch those
# deliberately instead.
#
# NOTE: built on `scan` into an array, NOT `capture`. jq's `capture` emits an
# EMPTY STREAM (not null) when the regex doesn't match, which inside a list
# comprehension silently drops the whole issue — so every issue with no
# "Blocked by:" line at all (i.e. exactly the unblocked ones we want)
# disappears and the watcher concludes "nothing ready" forever. Verified
# against synthetic and live board data; don't switch this back to `capture`.
# The dependency scan, the research exclusion, and the priority ordering are
# shared by both board modes and exist ONCE, here. label_names absorbs the
# shape difference: repo mode carries [{name: ...}] objects from `gh issue
# list`, project mode bare name strings from `gh project item-list`.
READY_RULES='
def label_names: (.labels // []) | map(if type == "object" then .name else . end);
def is_research: (label_names | index("research")) != null;
def prio: if (label_names | index("priority:high")) then 0 else 1 end;
def blocked_refs:
  ([(.body // "") | scan("Blocked by:[^\n]*"; "i")] | join(" "))
  | [scan("[0-9]+")] | map(tonumber);
def unblocked($open): (blocked_refs | any(. as $r | $open | index($r) != null)) | not;
def emit_ready: sort_by(.prio, .number) | .[] | "\(.nwo)\t\(.number)\t\(.title)";
'

READY_FILTER="$READY_RULES"'
[.[] | .number] as $open
| [ .[]
    | select(((label_names | (index("mgr:in-flight") or index("mgr:hold"))) or is_research) | not)
    | select(unblocked($open))
    | { nwo: $repo, number, title, prio: prio }
  ]
| emit_ready
'

# --- repo backend: the original mgr:* label state machine -------------------

repo_board_load() {
  inflight_data=$(gh issue list -R "$CUR_REPO" --state open --label mgr:in-flight --json number,title \
    --jq '.[] | "'"$CUR_REPO"'\t\(.number)\t\(.title)"' 2>"$ERRFILE") || return 1
}

# Prints ready issues, one per line, as "<nwo><TAB><number><TAB><title>".
repo_board_ready() {
  local data
  data=$(gh issue list -R "$CUR_REPO" --state open --json number,title,labels,body --limit 200 2>"$ERRFILE") || return 1
  [ -z "$data" ] && return 0
  jq -r --arg repo "$CUR_REPO" "$READY_FILTER" <<<"$data" 2>/dev/null
}

mutation_error_class() { # <stderr file>
  local e
  e=$(cat "$1" 2>/dev/null)
  case "$e" in
    *"rate limit"*|*"secondary rate"*|*"abuse detection"*|*"HTTP 429"*) printf 'rate limited' ;;
    *"missing required scopes"*|*"Bad credentials"*|*uthentication*|*"HTTP 401"*|*"HTTP 403"*|*"permission denied"*) printf 'authentication/authorization failure' ;;
    *"Could not resolve"*|*"no such host"*|*"connection refused"*|*"dial tcp"*|*imeout*|*"TLS"*) printf 'network failure' ;;
    *"HTTP 5"*|*"service unavailable"*|*"internal server error"*) printf 'remote API failure' ;;
    *"HTTP 404"*|*"not found"*) printf 'not found' ;;
    *"HTTP 409"*|*"already exists"*|*"already labeled"*) printf 'claim conflict' ;;
    "") printf 'no diagnostic output' ;;
    *) printf 'unclassified gh failure' ;;
  esac
}
run_board_mutation() {
  : >"$MUTATION_ERRFILE"
  "$@" >/dev/null 2>"$MUTATION_ERRFILE"
  BOARD_MUTATION_RC=$?
  BOARD_MUTATION_CLASS=$(mutation_error_class "$MUTATION_ERRFILE")
  return "$BOARD_MUTATION_RC"
}
board_mutation_diag() {
  printf 'command exited %s (%s)' "$BOARD_MUTATION_RC" "$BOARD_MUTATION_CLASS"
}
repo_board_claim() { run_board_mutation gh issue edit "$2" -R "$1" --add-label mgr:in-flight; }      # <nwo> <num>
repo_board_release() { run_board_mutation gh issue edit "$2" -R "$1" --remove-label mgr:in-flight; } # <nwo> <num>
repo_board_claim_state() { # <nwo> <num>
  local state rc
  state=$(gh issue view "$2" -R "$1" --json labels --jq '[.labels[].name] | index("mgr:in-flight") // empty' 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || { printf 'unknown'; return 0; }
  [ -n "$state" ] && printf 'present' || printf 'absent'
}

# A closed issue still carrying mgr:in-flight is pure residue: the label no
# longer gates anything (capacity only counts open issues) but it is exactly
# what accumulates into a board nobody can read. Sessions sometimes close the
# issue and exit before dropping it. No judgment needed once the issue is
# closed, so strip it.
repo_board_finish() { # <nwo> <num>
  if gh issue view "$2" -R "$1" --json labels --jq '[.labels[].name] | index("mgr:in-flight") // empty' 2>/dev/null | grep -q .; then
    board_release "$1" "$2" \
      && log "issue #$2: stripped stale mgr:in-flight from a closed issue"
  fi
}

# --- project backend: the board's Status single-select ----------------------

# Every assumption about the Projects v2 item shape lives in this ONE filter,
# so a field-name correction is a one-line fix. Shape per gh 2.94's own
# serializer: items[] = { id, content: {type, body, title, number,
# repository, url}, <camelCased field name>: <value>, ... } - the Status
# single-select arrives as .status (the option NAME), the board's built-in
# Labels field as .labels (bare name strings; a board that removed that field
# shows the label rules no labels at all). content carries NO open/closed
# state, which is why board_load also fetches each mapped repo's open issue
# numbers ($openmap: nwo -> [numbers]). Draft items, PRs, and items of
# repos outside the board's map ($repos, the mapped nwo list) are dropped
# here; the unmapped ones are additionally reported — once per (board,
# repo) — by project_board_load.
PROJECT_NORMALIZE='
[ .items[]?
  | (.content.repository // "") as $r
  | select((.content.type // "") == "Issue"
           and (($repos | index($r)) != null))
  | .content.number as $n
  | { nwo: $r,
      number: $n,
      title: (.content.title // ""),
      item: .id,
      status: (.status // ""),
      state: (if (($openmap[$r] // []) | index($n)) != null then "OPEN" else "CLOSED" end),
      labels: (.labels // []),
      body: (.content.body // "") } ]
'

project_items="[]"
project_open_map="{}"

project_board_load() {
  local raw mapped_json r open_json
  raw=$(gh project item-list "$CUR_NUMBER" --owner "$CUR_OWNER" --format json --limit 200 2>"$ERRFILE") || return 1
  mapped_json=$(cut -f1 <<<"$CUR_REPOMAP" | jq -R . | jq -cs .)

  # Open/closed state per repo: one open-issue-number fetch per MAPPED repo
  # that actually has issue items on the board this cycle.
  project_open_map="{}"
  while read -r r; do
    [ -z "$r" ] && continue
    open_json=$(gh issue list -R "$r" --state open --json number --limit 200 --jq '[.[].number]' 2>"$ERRFILE") || return 1
    [ -z "$open_json" ] && open_json="[]"
    project_open_map=$(jq -c --arg r "$r" --argjson o "$open_json" '. + {($r): $o}' <<<"$project_open_map")
  done <<<"$(jq -r --argjson repos "$mapped_json" \
      '[.items[]? | select((.content.type // "") == "Issue") | .content.repository // ""]
       | unique | .[] | . as $r | select($r != "" and (($repos | index($r)) != null))' <<<"$raw" 2>/dev/null)"

  project_items=$(jq -c --argjson repos "$mapped_json" --argjson openmap "$project_open_map" \
    "$PROJECT_NORMALIZE" <<<"$raw" 2>/dev/null)
  [ -z "$project_items" ] && project_items="[]"
  inflight_data=$(jq -r '.[] | select(.status == "In progress" and .state == "OPEN") | "\(.nwo)\t\(.number)\t\(.title)"' <<<"$project_items" 2>/dev/null)

  # Items of repos OUTSIDE the map are SKIPPED, not held: their cards stay
  # in Todo untouched — a Status write is a semantic statement about the
  # work, and "the watcher is misconfigured" is not one — and the operator
  # is told exactly once per (board, repo). Silently dropping them is this
  # project's recurring silent-park bug; repeating the notice every poll is
  # noise. A watcher restart re-firing it once is acceptable.
  while read -r r; do
    [ -z "$r" ] && continue
    skip_once "$r" || continue
    log "board $CUR_NAME: skipping project items of unmapped repo $r (not in this board's repos config)"
    report "skipping this project's items in $r: that repo is not in this board's repo map. Cards left in Todo untouched; add the repo to the config and restart to dispatch them."
  done <<<"$(jq -r --argjson repos "$mapped_json" \
      '[.items[]? | select((.content.type // "") == "Issue") | .content.repository // ""]
       | unique | .[] | . as $r | select($r != "" and (($repos | index($r)) == null))' <<<"$raw" 2>/dev/null)"

  # Reconcile residue on every load, not only on departure: a closed issue
  # whose card is still In progress (left over from before a watcher
  # restart, say) never appears in flight, so it would never be seen
  # departing and never reach Done.
  while IFS=$'\t' read -r r n; do
    [ -z "$n" ] && continue
    project_board_finish "$r" "$n"
  done <<<"$(jq -r '.[] | select(.state == "CLOSED" and .status == "In progress") | "\(.nwo)\t\(.number)"' <<<"$project_items" 2>/dev/null)"
}

project_board_ready() {
  jq -r --argjson openmap "$project_open_map" "$READY_RULES"'
  [ .[]
    | select(.state == "OPEN" and .status == "Todo")
    | select(is_research | not)
    | select(unblocked($openmap[.nwo] // []))
    | { nwo, number, title, prio: prio }
  ]
  | emit_ready' <<<"$project_items" 2>/dev/null
}

project_item_id_for() { jq -r --arg r "$1" --argjson n "$2" 'first(.[] | select(.nwo == $r and .number == $n)) | .item // empty' <<<"$project_items" 2>/dev/null; } # <nwo> <num>
project_status_for() { jq -r --arg r "$1" --argjson n "$2" 'first(.[] | select(.nwo == $r and .number == $n)) | .status // empty' <<<"$project_items" 2>/dev/null; } # <nwo> <num>

project_set_status() { # <item id> <option id>
  run_board_mutation gh project item-edit --id "$1" --project-id "$CUR_PROJECT_ID" --field-id "$CUR_STATUS_FIELD_ID" --single-select-option-id "$2"
}

project_board_claim() { # <nwo> <num>
  local item
  item=$(project_item_id_for "$1" "$2")
  if [ -z "$item" ]; then
    BOARD_MUTATION_RC=1
    BOARD_MUTATION_CLASS="project item not found"
    return 1
  fi
  project_set_status "$item" "$CUR_OPT_IN_PROGRESS"
}

project_board_release() { # <nwo> <num>
  local item
  item=$(project_item_id_for "$1" "$2")
  if [ -z "$item" ]; then
    BOARD_MUTATION_RC=1
    BOARD_MUTATION_CLASS="project item not found"
    return 1
  fi
  project_set_status "$item" "$CUR_OPT_TODO"
}

# Moves a CLOSED issue's card to Done, once. PROJECT_DONE_SYNCED (persisted
# per board as BOARD_<i>_DONE_SYNCED) remembers the "<nwo>#<num>" keys
# already moved so the load-time residue sweep and the departure pass cannot
# double-edit the same card in one cycle.
PROJECT_DONE_SYNCED=""
project_board_finish() { # <nwo> <num>
  local nwo="$1" num="$2" item status
  if grep -qxF "$nwo#$num" <<<"$PROJECT_DONE_SYNCED"; then return 0; fi
  [ -n "$CUR_OPT_DONE" ] || return 0
  status=$(project_status_for "$nwo" "$num")
  case "$status" in ""|Done) return 0 ;; esac
  item=$(project_item_id_for "$nwo" "$num")
  [ -n "$item" ] || return 0
  if project_set_status "$item" "$CUR_OPT_DONE"; then
    PROJECT_DONE_SYNCED=$(printf '%s\n%s' "$PROJECT_DONE_SYNCED" "$nwo#$num")
    log "issue #$num: closed issue's card moved to Done"
  fi
}

# --- dispatch ---------------------------------------------------------------

# BOARD_FETCH_OK tracks whether the current board's load fetch succeeded, so
# board_inflight can honor the error-vs-empty contract too: rc 1 after a
# failed load, rc 0 with empty output only for a really empty board.
BOARD_FETCH_OK=0
board_load() {
  BOARD_FETCH_OK=0
  if [ "$CUR_KIND" = "project" ]; then
    project_board_load || return 1
  else
    repo_board_load || return 1
  fi
  BOARD_FETCH_OK=1
}
# Both backends load inflight_data in the same "<nwo>\t<number>\t<title>"
# shape (title_for depends on it too), so slicing the keys out is
# mode-independent. Keys are the repo-qualified "<nwo>#<number>", not bare
# numbers: two repos — on one cross-repo board, or across boards — can
# reuse issue numbers.
board_inflight() {
  [ "$BOARD_FETCH_OK" = 1 ] || return 1
  awk -F'\t' 'NF { print $1 "#" $2 }' <<<"$inflight_data" 2>/dev/null | sort
}
board_ready() { if [ "$CUR_KIND" = "project" ]; then project_board_ready; else repo_board_ready; fi; }
board_claim() { if [ "$CUR_KIND" = "project" ]; then project_board_claim "$1" "$2"; else repo_board_claim "$1" "$2"; fi; }
board_release() {
  if [ "$CUR_KIND" = "project" ]; then
    project_board_release "$1" "$2"
  else
    repo_board_release "$1" "$2"
  fi
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    log "issue #$2: $CLAIM_NOUN release failed: $(board_mutation_diag); board state may remain claimed"
    report "issue #$2: could not release $CLAIM_NOUN: $(board_mutation_diag). State may remain claimed; inspect before retrying."
  fi
  return "$rc"
}
board_finish() { if [ "$CUR_KIND" = "project" ]; then project_board_finish "$1" "$2"; else repo_board_finish "$1" "$2"; fi; }

# Converts an ISO-8601 UTC timestamp ("2026-09-10T12:00:00Z") to epoch
# seconds. BSD date (macOS) and GNU date (Linux) take incompatible flags for
# this: try BSD's first, then GNU's.
iso_to_epoch() {
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null
}

# First time we see an issue in flight with no recorded start, ask GitHub
# when mgr:in-flight was actually applied rather than assuming "now" — the
# issue may have been claimed before this watcher started, or by a prior
# run (or since a marker comment's own recorded start, by a prior flight
# period). Falls back to now if the timeline has no such event or the call
# fails. Returns an ISO-8601 UTC timestamp, GitHub's own format.
fetch_start_iso() { # <nwo> <num>
  local nwo="$1" num="$2" ts
  # The timeline is oldest-first and defaults to 30 events per page (100
  # max). Without --paginate, a timeline longer than one page hides the
  # CURRENT flight period's labeling behind older history on page one, so
  # `| last` picks the last match on page one - the oldest page - not the
  # most recent labeling. `--paginate` walks every page, but `--jq` runs
  # once per page rather than once over the concatenated result, so this
  # prints one line per matching event across all pages; sort them and take
  # the max instead of trusting document order. per_page=100 in the query
  # string (NOT `-f`/`-F`, which silently turns a GET into a POST and 404s)
  # cuts the page count for long timelines rather than paging at the
  # default 30/page.
  #
  # A failed or partial call can put an HTTP error's JSON body on stdout
  # instead of a timestamp (gh does not route it to stderr), and `{`/`}`
  # byte-sort ahead of every digit, so an unvalidated result would look
  # newer than any real timestamp to the caller and poison the marker
  # comment. Require the exact GitHub timestamp shape before trusting it.
  ts=$(gh api --paginate "repos/$nwo/issues/$num/timeline?per_page=100" \
        --jq '.[] | select(.event=="labeled" and .label.name=="mgr:in-flight") | .created_at' \
        2>/dev/null | sort | tail -n1)
  case "$ts" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) printf '%s' "$ts" ;;
    *) date -u +%FT%TZ ;;
  esac
}

# State for the long-running-issue notices lives on the issue itself, as a
# single hidden-marker comment, so it survives a watcher restart, a wiped
# /tmp, or a machine change, and a human can read it: GitHub is the source
# of truth, not a local file.
FLIGHT_MARKER='<!-- work-the-board:flight -->'

# Prints "<comment_id><TAB><start_iso><TAB><hours_reported>" for issue $1's
# marker comment, or nothing if it has none yet. The comment id is parsed
# out of the comment's HTML URL ("...#issuecomment-<id>") since `gh issue
# view --json comments` exposes only the GraphQL node id, not the numeric
# id the REST PATCH endpoint needs.
age_comment_for() { # <nwo> <num>
  local nwo="$1" num="$2" data url body cid start hours
  data=$(gh issue view "$num" -R "$nwo" --json comments --jq \
    '[.comments[] | select(.body | startswith("'"$FLIGHT_MARKER"'"))] | last
     | if . == null then empty else "\(.url)\u0001\(.body)" end' \
    2>/dev/null)
  [ -z "$data" ] && return 0
  url="${data%%$'\x01'*}"
  body="${data#*$'\x01'}"
  cid="${url##*#issuecomment-}"
  start=$(awk -F': ' '/^in-flight start:/{print $2; exit}' <<<"$body")
  hours=$(awk -F': ' '/^hours reported:/{print $2; exit}' <<<"$body")
  [ -z "$hours" ] && hours=0
  printf '%s\t%s\t%s\n' "$cid" "$start" "$hours"
}

# Renders the marker comment body: the marker line plus two human-readable
# lines an operator can read directly on the issue.
flight_comment_body() {
  printf '%s\nin-flight start: %s\nhours reported: %s\n' "$FLIGHT_MARKER" "$1" "$2"
}

# Creates the marker comment and prints the new comment's numeric id.
create_flight_comment() { # <nwo> <num> <body>
  local nwo="$1" num="$2" body="$3" url
  url=$(gh issue comment "$num" -R "$nwo" --body "$body" 2>/dev/null)
  printf '%s' "${url##*#issuecomment-}"
}

# Rewrites the marker comment in place. Called only on an hour boundary or a
# clock reset, never every cycle, and never posts a second comment.
update_flight_comment() { # <nwo> <comment id> <body>
  gh api --method PATCH "repos/$1/issues/comments/$2" -f "body=$3" >/dev/null 2>&1
}

# GitHub is the durable record for flight-age state, but it is only READ the
# first time this process sees an issue in flight and only WRITTEN when an
# hour boundary fires; every other scan is served from this in-memory
# mirror. One
# "<nwo>#<num>\t<start_iso>\t<start_epoch>\t<hours_reported>\t<comment_id>"
# row per in-flight issue — keyed by the repo-qualified "<nwo>#<num>", since
# a cross-repo board's repos can reuse issue numbers — in a plain
# newline-delimited string: this script runs on bash 3.2, which has no
# associative arrays. FLIGHT_SEEN_DEPART lists the keys that left flight
# while this process watched, so a re-entry is distinguishable from first
# sight after a restart. Both are persisted per board
# (BOARD_<i>_FLIGHT_CACHE / _FLIGHT_SEEN_DEPART) around each service_board
# call.
FLIGHT_CACHE=""
FLIGHT_SEEN_DEPART=""

flight_cache_row() { awk -F'\t' -v n="$1" '$1 == n { print; exit }' <<<"$FLIGHT_CACHE"; }
flight_cache_drop() { FLIGHT_CACHE=$(awk -F'\t' -v n="$1" 'NF && $1 != n' <<<"$FLIGHT_CACHE"); }
flight_cache_put() { # <key> <start_iso> <start_epoch> <hours> <comment_id>
  flight_cache_drop "$1"
  FLIGHT_CACHE=$(printf '%s\n%s\t%s\t%s\t%s\t%s' "$FLIGHT_CACHE" "$1" "$2" "$3" "$4" "$5")
}

# Looks up an in-flight issue's title from this cycle's $inflight_data.
title_for() { # <nwo> <num>
  awk -F'\t' -v r="$1" -v n="$2" '$1==r && $2==n{print $3; exit}' <<<"$inflight_data"
}

# Closes tabs belonging to finished issues. This is a backstop, not the normal
# path: next-issue now closes its own tab on `done`. It exists for a session
# that dies, is killed, or exits before it gets there and leaves its tab behind.
#
# Runs EVERY cycle, not once on departure: at the moment an issue closes its
# worktree is usually still being torn down, so a one-shot sweep would decline
# to close it and then never look again. Reconciling each cycle picks it up on
# a later pass instead.
#
# A tab is only closed when its issue is CLOSED *and* its worktree is gone.
# A surviving worktree usually means the session is still finishing its own
# teardown, and closing the tab under it would kill that mid-step - but it
# can also just mean a permanent orphan nothing reclaims: sweep_orphan_worktrees
# (below) only ever closes a stray herdr WORKSPACE REGISTRATION, it never
# removes a git checkout, so a leftover worktree can sit here indefinitely
# either way and this sweep still declines to touch the tab regardless.
#
# Labels are board-scoped — "<board>/issue-<n>: <title>" — and each board
# sweeps only its own tabs, checking the closed state and the worktree
# against ITS OWN mapped repos and paths. The label carries the board and
# number but not the repo, so a cross-repo board checks every mapped repo:
# the tab closes only when no mapped repo has the issue OPEN, at least one
# has it CLOSED, and no mapped checkout still holds an issue-<n> worktree.
#
# NOTE: a bare `issue-<N>:`-labeled tab (the old per-worktree-workspace
# mechanism's leftover shape, from before this board-scoped naming) has its
# stray WORKSPACE REGISTRATION closed automatically by sweep_orphan_worktrees
# (below, registration only, checkout untouched; closing a workspace closes
# its tabs too) once its issue number leaves flight everywhere — but only
# when that tab lives inside a linked-worktree workspace, which is what the old mechanism
# always created. A bare-labeled tab sitting inside a repo's own PRIMARY
# workspace (e.g. from a standalone next-issue session, or hand-moved
# there) is reachable by NEITHER sweep: is_linked_worktree is always false
# for a primary workspace, so sweep_orphan_worktrees's candidate filter
# excludes it, and its bare label does not match this function's
# board-scoped pattern either. Such tabs still need a manual `herdr tab
# rename`/close pass.
sweep_finished_tabs() {
  local tabs tab bname num r p state any_closed keep

  # Emit "<tab_id><TAB><board><TAB><issue number>" straight from jq. Do NOT
  # parse the number out with sed: "\+" is a GNU extension that BSD sed
  # (macOS) treats as a literal plus, so the number came back empty and
  # nothing was ever swept — silently, because an empty number just skips
  # the tab.
  tabs=$(herdr tab list 2>/dev/null \
         | jq -r '.result.tabs[]?
                  | select(.label? // "" | test("^[a-z0-9-]+/issue-[0-9]+:"))
                  | (.label | capture("^(?<b>[a-z0-9-]+)/issue-(?<n>[0-9]+):")) as $m
                  | "\(.tab_id)\t\($m.b)\t\($m.n)"')
  [ -z "$tabs" ] && return 0

  while IFS=$'\t' read -r tab bname num; do
    [ -z "$tab" ] || [ -z "$num" ] && continue
    [ "$bname" = "$CUR_NAME" ] || continue

    keep=0
    any_closed=0
    while IFS=$'\t' read -r r p _ws; do
      [ -z "$r" ] && continue
      # still holding a slot? then it is not finished
      grep -qxF "$r#$num" <<<"$inflight" && { keep=1; break; }
      state=$(gh issue view "$num" -R "$r" --json state --jq '.state' 2>/dev/null)
      case "$state" in
        OPEN) keep=1; break ;;
        CLOSED) any_closed=1 ;;
      esac
      git -C "$p" worktree list 2>/dev/null | grep -qE "issue-$num([^0-9]|$)" && { keep=1; break; }
    done <<<"$CUR_REPOMAP"
    [ "$keep" -eq 1 ] && continue
    [ "$any_closed" -eq 1 ] || continue

    if herdr tab close "$tab" >/dev/null 2>&1; then
      log "issue #$num: closed finished tab $tab"
      report "closed issue #$num's finished tab ($tab): landed, worktree gone, session done."
    fi
  done <<<"$tabs"
}

# Returns success (0) if any line of <live_paths> (a TSV, one live agent per
# line, "<cwd><TAB><foreground_cwd>", either field possibly empty) names a
# cwd or foreground_cwd equal to <checkout_path>, or nested under it. This
# is ONE of three cross-workspace liveness signals sweep_orphan_worktrees
# relies on (see #25 and #25 review round 2 B1): an agent's own pane lives
# in the repo's PRIMARY workspace, not necessarily inside the candidate
# (stray, linked-worktree) workspace being considered, so this must be
# checked against every live agent everywhere, never scoped to panes of the
# candidate workspace itself. This path signal alone is NOT sufficient: a
# board-launched session's shell cwd stays at the repo's primary checkout
# forever (launch_issue passes it as `--cwd`, and the session works its
# worktree via absolute/-C paths, never `cd`s there), so this check never
# fires for the normal board-launched shape. See agent_name_owns_issue and
# agent_tab_owns_issue below for the two signals that do.
#
# <checkout_path> is stripped of one trailing slash, and treated as
# never-matching when empty (missing checkout_path data must never match
# every candidate by accident of how the prefix-strip below would otherwise
# degenerate on an empty string). Each live-agent path is also stripped of
# one trailing slash before comparing, so a checkout path recorded with or
# without a trailing slash compares the same (#25 review round 2 M1).
# Callers SHOULD pass a canonicalized checkout (via repo_root_for) when one
# is available, falling back to the raw checkout_path otherwise; this
# function does not itself canonicalize live-agent paths via extra git
# calls, since checkout-side canonicalization plus the trailing-slash strip
# is sufficient given this is now defense-in-depth, not the primary signal.
#
# Prefix match uses bash parameter-expansion prefix removal
# (${p#"$checkout"/}), not [[ == prefix* ]] glob matching, since a real
# checkout path can contain glob metacharacters that would otherwise be
# misinterpreted.
agent_owns_checkout() { # <checkout_path> <live_paths>
  local checkout="$1" paths="$2" c f p
  # n3: empty checkout_path must never-match, not always-match.
  [ -z "$checkout" ] && return 1
  checkout="${checkout%/}"
  while IFS=$'\t' read -r c f; do
    for p in "$c" "$f"; do
      p="${p%/}"
      [ -z "$p" ] && continue
      [ "$p" = "$checkout" ] && return 0
      [ "${p#"$checkout"/}" != "$p" ] && return 0
    done
  done <<<"$paths"
  return 1
}

# Returns success (0) if any line of <live_names> (one live agent's .name
# per line) matches launch_issue's own board-launched agent naming,
# "<board>-issue-<n>" (watch.sh launch_issue: `name="$CUR_NAME-issue-$num"`)
# for THIS issue number specifically. Second of three cross-workspace
# liveness signals for #25 review round 2 B1: this is what actually catches
# a normal board-launched session, since its shell cwd never moves into the
# worktree (see agent_owns_checkout above). Anchored on issue-number
# boundaries ((^|-) before, [^0-9]|$ after) so issue 25 never matches issue
# 250's or issue 2's own agent name.
#
# Deliberately NOT filtered by agent_status (n4): a `done`-status agent
# still counts as live/owning here — over-inclusive is the safe direction,
# and a future `working`-only filter would quietly narrow this guard.
#
# Deliberately board-agnostic (N3, #25 review round 2): matches ANY live
# agent's name carrying this issue number, not just this board's own
# "$CUR_NAME-issue-$num". Cross-board over-protection is the safe
# direction — a same-numbered issue owned by a different board's session
# is rare, but skipping it costs nothing, while narrowing to this board
# only would reopen a gap for that rare case.
agent_name_owns_issue() { # <num> <live_names>
  local num="$1" names="$2" n
  [ -z "$num" ] && return 1
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    [[ "$n" =~ (^|-)issue-$num([^0-9]|$) ]] && return 0
  done <<<"$names"
  return 1
}

# Returns success (0) if any of <tab_ids> (one live agent's own .tab_id per
# line, from `herdr agent list`) resolves, via <tab_label_map> (a TSV
# "<tab_id><TAB><label>" built from a single global `herdr tab list` call),
# to a label matching launch_issue's own tab-rename shape,
# "<board>/issue-<n>: <title>" (watch.sh launch_issue:
# `herdr tab rename "$tab" "$CUR_NAME/issue-$num: $title"`). Third of three
# cross-workspace liveness signals for #25 review round 2 B1, same
# rationale as agent_name_owns_issue above. Same board-prefix-optional,
# issue-boundary-anchored pattern already used by sweep_orphan_worktrees'
# own num-from-tab-label lookup and by sweep_finished_tabs.
#
# Deliberately NOT filtered by agent_status (n4) — see agent_name_owns_issue.
#
# Deliberately board-agnostic (N3, #25 review round 2), same rationale as
# agent_name_owns_issue above. This also matters for real data: a
# standalone (non-board) next-issue session's tab carries a bare
# "issue-<n>:" label with no board prefix, which this pattern already
# covers by design — narrowing it to a specific board would break that
# shape, not just over-narrow the cross-board case.
agent_tab_owns_issue() { # <num> <tab_ids> <tab_label_map>
  local num="$1" ids="$2" map="$3" t label
  [ -z "$num" ] && return 1
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    label=$(awk -F'\t' -v t="$t" '$1==t{print $2; exit}' <<<"$map")
    [ -z "$label" ] && continue
    [[ "$label" =~ ^([a-z0-9-]+/)?issue-$num: ]] && return 0
  done <<<"$ids"
  return 1
}

# Reaps stray herdr WORKSPACE REGISTRATIONS left over from the OLD
# (now-removed) per-worktree-workspace mechanism — `next-issue`'s prior
# `herdr worktree create` call always created a second, separate herdr
# workspace as a side effect of making the checkout — or from a hand-run/
# other-tool `herdr worktree create`. Runs once per board per cycle, right
# after sweep_finished_tabs. Local herdr/git calls only, zero GitHub calls,
# so it never touches this file's GitHub rate-limit accounting.
#
# This function ONLY ever closes a herdr workspace registration — it never
# deletes a git checkout. #14's original complaint was workspace-list
# clutter from these stray registrations, not on-disk checkouts; deleting a
# working tree is far more destructive than that clutter, so the two must
# never be coupled again (see #25, where this sweep's old `herdr worktree
# remove` action deleted the on-disk checkout of a session actively working
# from it).
#
# A candidate is a live workspace with worktree.is_linked_worktree true
# whose worktree.repo_root resolves to one of THIS board's mapped repos
# (never another board's, and never a repo's own primary workspace, which
# always has is_linked_worktree false). Its issue number comes from, in
# order: its checkout_path's basename against ^issue-([0-9]+)([^0-9]|$), or
# else any of its own tabs' labels against ^([a-z0-9-]+/)?issue-([0-9]+):.
# No number found at all (a hand-made worktree, a deploy/preview checkout,
# anything not issue-shaped) means the workspace is never touched.
#
# A number found but still in flight (this board's $inflight or the
# cross-board $CYCLE_SEEN) is a fast-path skip — but it is never, by
# itself, sufficient to prove a candidate reapable. mgr:hold and every
# other non-in-flight label state is UNKNOWN ownership, not unowned: a
# session can be actively working a held/parked issue from its checkout.
#
# The real, always-run gate is THREE independent cross-workspace live-agent
# signals (#25 review round 2 B1), each fetched ONCE per sweep — never per
# candidate — and reused for every candidate:
#   1. agent_owns_checkout: live cwd/foreground_cwd path containment, from
#      a single `herdr agent list` call.
#   2. agent_name_owns_issue: live agent .name matching this issue, from
#      the SAME `herdr agent list` call (no extra herdr call).
#   3. agent_tab_owns_issue: live agent's own tab label matching this
#      issue, from that same agent list's .tab_id fields plus a single
#      global `herdr tab list` call (also fetched once per sweep).
# Signal 1 alone is what #25's original fix shipped, and by itself never
# fires for a normal board-launched session (its shell cwd never enters the
# worktree — see agent_owns_checkout's doc comment). Signals 2 and 3 are
# what actually protect that shape. A candidate is skipped whenever ANY of
# the three matches, in ANY workspace — this is what protects a session
# whose own pane/agent identity lives in the repo's primary workspace while
# the stray workspace under consideration sits elsewhere, the exact shape
# that broke in the #25 incident. Fetching/parsing `herdr agent list`
# failing fails the WHOLE sweep closed for this cycle (return 0
# immediately), since without that data no candidate can be proven unowned;
# a `herdr tab list` failure only degrades signal 3 (empty tab_label_map),
# since signals 1 and 2 still stand guard.
#
# A FOURTH, independent guard (M4, restored #25 review round 2 B2): a live
# agent whose pane sits INSIDE the candidate workspace itself (e.g. moved
# in via `herdr pane move`, or one whose cwd genuinely is the checkout) is
# checked per-candidate via `herdr pane list --workspace`, counting panes
# with an `agent` field. This does not replace the three signals above —
# it is defense in depth for the case none of them, being identity-based,
# happens to catch.
#
# Local-only safety guard (M3), unrelated to the live-agent checks: an
# open, deliberately parked issue can still have a real, clean, pushed
# checkout here. A candidate is skipped, not closed, when its checkout has
# no upstream tracking branch (no upstream is itself a signal this could be
# uncommitted-to-remote or user-created work) or has any commit ahead of
# its upstream; the check failing for any reason is treated the same as
# "unpushed work exists" (fail closed). This is now only a
# visibility/decluttering signal, not a data-loss guard — the checkout is
# never deleted by this function — but an unpushed/dirty checkout is still
# worth leaving its workspace card visible for. When the checkout directory
# no longer exists on disk at all (#25 review round 2 M2 — the now-common
# shape where a session removed its own worktree on `done`), this probe is
# skipped entirely and the registration is closed straight away: a missing
# directory can never have a live agent (already excluded above) or
# unpushed work worth surfacing, and failing this closed forever would
# permanently block reaping exactly the leftover registrations #25's
# acceptance criteria call out.
#
# Everything else is reaped: `herdr workspace close <id>` only. This
# unregisters the stray workspace; the checkout stays on disk, untouched,
# forever (when it still exists) — this sweep must never delete a git
# checkout again. A close failure, or any of the skip reasons above, is
# reported exactly once via skip_once's latch, not every cycle, and
# retried plainly on later cycles.
sweep_orphan_worktrees() {
  local ws_out map r p _ws root candidates ws_id ws_checkout ws_root
  local nwo base num key close_out close_rc checkout_canon checkout_missing
  local has_upstream ahead agent_out agent_rc live_paths live_names live_tab_ids
  local tab_out tab_label_map live_reason pane_out pane_rc has_agent

  ws_out=$(herdr workspace list 2>/dev/null) || return 0
  jq -e . >/dev/null 2>&1 <<<"$ws_out" || return 0

  map=""
  while IFS=$'\t' read -r r p _ws; do
    [ -z "$r" ] && continue
    root=$(repo_root_for "$p") || continue
    map="$map
$root	$r"
  done <<<"$CUR_REPOMAP"
  [ -z "$map" ] && return 0

  candidates=$(jq -r '.result.workspaces[]?
    | select((.worktree? // null) != null and (.worktree.is_linked_worktree? // false) == true)
    | [.workspace_id, (.worktree.checkout_path // ""), (.worktree.repo_root // "")] | @tsv' <<<"$ws_out")
  [ -z "$candidates" ] && return 0

  # Cross-workspace live-agent snapshot (see doc comment above): fetched
  # ONCE, reused for every candidate. Fail closed for the whole sweep, not
  # per-candidate, if it cannot be trusted (n1: single collapsed check,
  # no write-once agent_ok temp).
  agent_out=$(herdr agent list 2>/dev/null)
  agent_rc=$?
  if [ "$agent_rc" -ne 0 ] || ! jq -e . >/dev/null 2>&1 <<<"$agent_out"; then
    if skip_once "orphan-agent-list-failed"; then
      log "orphan sweep: herdr agent list failed or returned invalid JSON — cannot confirm no live agent owns any candidate checkout, skipping this cycle"
      report "orphan sweep: herdr agent list failed or returned invalid JSON — cannot confirm no live agent owns any candidate checkout, skipping this cycle"
    fi
    return 0
  fi
  live_paths=$(jq -r '.result.agents[]? | [(.cwd // ""), (.foreground_cwd // "")] | @tsv' <<<"$agent_out")
  live_names=$(jq -r '.result.agents[]? | (.name // "")' <<<"$agent_out")
  live_tab_ids=$(jq -r '.result.agents[]? | (.tab_id // "")' <<<"$agent_out")

  # Global tab-label map for signal 3 (agent_tab_owns_issue), fetched ONCE
  # per sweep — same call shape sweep_finished_tabs already uses. A failure
  # here only degrades signal 3 to no-match (empty map); it does not fail
  # the whole sweep closed, since signals 1 and 2 above still stand guard.
  tab_out=$(herdr tab list 2>/dev/null)
  tab_label_map=""
  if jq -e . >/dev/null 2>&1 <<<"$tab_out"; then
    tab_label_map=$(jq -r '.result.tabs[]? | [.tab_id, (.label // "")] | @tsv' <<<"$tab_out")
  fi

  while IFS=$'\t' read -r ws_id ws_checkout ws_root; do
    [ -z "$ws_id" ] && continue
    # N1 (#25 review round 2): herdr can report worktree data transiently
    # (see :446-450's documented "worktree: null" retry precedent) — an
    # empty checkout_path means there is no on-disk path to confirm
    # anything about, so never make a close decision from it; wait for a
    # later cycle where herdr reports it populated.
    [ -z "$ws_checkout" ] && continue
    nwo=$(awk -F'\t' -v r="$ws_root" '$1==r{print $2; exit}' <<<"$map")
    [ -z "$nwo" ] && continue

    base=$(basename -- "$ws_checkout")
    num=""
    if [[ "$base" =~ ^issue-([0-9]+)([^0-9]|$) ]]; then
      num="${BASH_REMATCH[1]}"
    fi
    if [ -z "$num" ]; then
      num=$(herdr tab list 2>/dev/null \
            | jq -r --arg ws "$ws_id" '
                .result.tabs[]?
                | select(.workspace_id == $ws)
                | select(.label? // "" | test("^([a-z0-9-]+/)?issue-[0-9]+:"))
                | (.label | capture("^([a-z0-9-]+/)?issue-(?<n>[0-9]+):")).n' \
            | head -1)
    fi
    [ -z "$num" ] && continue

    key="$nwo#$num"
    grep -qxF "$key" <<<"$inflight" && continue
    grep -qxF "$key" <<<"$CYCLE_SEEN" && continue

    # Cross-workspace live-agent guard — the actual #25 fix, now three
    # independent signals (see doc comment above). Never sufficient to skip
    # based on in-flight/label state alone; this must run for every
    # candidate that reaches here. M1: canonicalize the checkout via
    # repo_root_for before the path check, falling back to the raw
    # checkout_path if that fails (e.g. the checkout no longer exists).
    checkout_canon=$(repo_root_for "$ws_checkout" 2>/dev/null) || checkout_canon="$ws_checkout"
    live_reason=""
    if agent_owns_checkout "$checkout_canon" "$live_paths"; then
      live_reason="live agent cwd/foreground_cwd path inside the checkout"
    elif agent_name_owns_issue "$num" "$live_names"; then
      live_reason="live agent name matches issue #$num"
    elif agent_tab_owns_issue "$num" "$live_tab_ids" "$tab_label_map"; then
      live_reason="live agent's own tab label matches issue #$num"
    fi
    if [ -n "$live_reason" ]; then
      if skip_once "orphan-live-agent:$ws_id"; then
        log "orphan workspace $ws_id (issue #$num, $nwo): live agent found ($live_reason) — left untouched, not closed"
      fi
      continue
    fi

    # Per-candidate-workspace live-pane guard (M4, restored #25 review
    # round 2 B2): independent of the three cross-workspace signals above —
    # protects a pane holding a live agent that sits INSIDE the candidate
    # workspace itself. Fail closed on any herdr/jq failure or non-numeric
    # count.
    pane_out=$(herdr pane list --workspace "$ws_id" 2>/dev/null)
    pane_rc=$?
    if [ "$pane_rc" -ne 0 ] || ! jq -e . >/dev/null 2>&1 <<<"$pane_out"; then
      if skip_once "orphan-pane-list-failed:$ws_id"; then
        log "orphan workspace $ws_id (issue #$num, $nwo): herdr pane list failed or returned invalid JSON — left untouched, cannot confirm no live agent"
      fi
      continue
    fi
    has_agent=$(jq -r '[.result.panes[]? | select(has("agent"))] | length' <<<"$pane_out" 2>/dev/null)
    case "$has_agent" in
      ''|*[!0-9]*)
        if skip_once "orphan-pane-count-invalid:$ws_id"; then
          log "orphan workspace $ws_id (issue #$num, $nwo): could not determine live-pane count (got '$has_agent') — left untouched"
        fi
        continue
        ;;
    esac
    if [ "$has_agent" -gt 0 ]; then
      if skip_once "orphan-live-agent-pane:$ws_id"; then
        log "orphan workspace $ws_id (issue #$num, $nwo): live agent found (pane inside the candidate workspace itself) — left untouched, not closed"
      fi
      continue
    fi

    # M2: a checkout directory that no longer exists on disk can never have
    # a live agent (already excluded above) or unpushed work worth
    # surfacing — skip the upstream/ahead probe entirely rather than
    # failing it closed forever (git -C <nonexistent> always fails).
    checkout_missing=0
    [ -d "$ws_checkout" ] || checkout_missing=1

    if [ "$checkout_missing" -eq 0 ]; then
      # Local-only safety guard (M3): never close a workspace whose
      # checkout has no upstream or has commits not yet pushed — fail
      # closed on any uncertainty. Visibility signal only now (see doc
      # comment above).
      has_upstream=1
      git -C "$ws_checkout" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || has_upstream=0
      ahead=""
      if [ "$has_upstream" -eq 1 ]; then
        ahead=$(git -C "$ws_checkout" rev-list --count '@{u}..HEAD' 2>/dev/null)
      fi
      if [ "$has_upstream" -ne 1 ] || [ -z "$ahead" ] || [ "$ahead" != "0" ]; then
        if skip_once "orphan-unpushed:$ws_id"; then
          log "orphan workspace $ws_id (issue #$num, $nwo): no upstream tracking branch, or unpushed commits ahead of upstream (or the check itself failed) — left untouched, not closed"
          report "found orphan workspace $ws_id for issue #$num ($nwo) but its checkout has no upstream or has commits not yet pushed (left untouched, not closed)"
        fi
        continue
      fi
    fi

    close_out=$(herdr workspace close "$ws_id" 2>&1)
    close_rc=$?
    if [ "$close_rc" -ne 0 ]; then
      if skip_once "orphan-close-failed:$ws_id"; then
        log "orphan workspace $ws_id (issue #$num, $nwo): workspace close failed: $close_out"
        report "found orphan workspace $ws_id for issue #$num ($nwo) but could not close its workspace registration (left untouched): $close_out"
      fi
      continue
    fi
    if [ "$checkout_missing" -eq 1 ]; then
      log "orphan workspace $ws_id (issue #$num, $nwo): closed stray per-worktree workspace registration (checkout path no longer exists on disk: $ws_checkout)"
      report "closed orphan workspace $ws_id: stray per-worktree workspace registration for issue #$num ($nwo), no live agent, issue not in flight, checkout path no longer exists on disk: $ws_checkout."
    else
      log "orphan workspace $ws_id (issue #$num, $nwo): closed stray per-worktree workspace registration (git checkout left on disk, untouched: $ws_checkout)"
      report "closed orphan workspace $ws_id: stray per-worktree workspace registration for issue #$num ($nwo), no live agent, issue not in flight, checkout clean and pushed. Git checkout left on disk, untouched: $ws_checkout."
    fi
  done <<<"$candidates"
}

# Prints "<pr_number><TAB><head_branch>" if an open PR already belongs to this
# issue, else nothing.
#
# Matching is deliberately narrow: the head branch carrying the issue number,
# or a closing keyword in the title/body. A bare "#N" mention is NOT enough —
# PRs routinely name related issues ("related #97/#98/#99 work is not copied"),
# and treating that as ownership hands a session the wrong branch.
existing_pr_for() { # <nwo> <num>
  gh pr list -R "$1" --state open --json number,headRefName,title,body --limit 100 2>/dev/null \
    | jq -r --arg n "$2" '
        [ .[]
          | select(
              (.headRefName | test("(^|[^0-9])" + $n + "([^0-9]|$)"))
              or ((.title + " " + (.body // ""))
                  | test("(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed))\\s+#" + $n + "([^0-9]|$)"; "i"))
            )
        ]
        | if length == 0 then "" else "\(.[0].number)\t\(.[0].headRefName)" end' 2>/dev/null
}

# Prints a remote branch name already carrying this issue number, if any.
existing_branch_for() { # <path> <num>
  git -C "$1" ls-remote --heads origin 2>/dev/null \
    | sed 's#.*refs/heads/##' \
    | grep -E "(^|[^0-9])$2([^0-9]|$)" \
    | head -1
}

# Re-establishes a usable herdr workspace for (current board, <nwo>) after its
# configured one vanished - herdr destroys a workspace when its last tab
# closes, so a workspace whose only tabs were transient sessions self-destructs
# (this is issue #19). Sets WS_ENSURE_NEW to the workspace id and rewrites
# the board's REPOMAP so every later launch this run uses it; rc 1 with the
# reason in WS_ENSURE_ERR when no workspace can be had.
#
# Resolve BEFORE create, always: the operator may have reopened the repo under
# a new id, and a sibling board over the same repo may have just recreated it.
# Adopting the live one keeps every board converged on ONE workspace per
# checkout, which is the whole point of #14's nesting rule; blind creation
# would fork it.
WS_ENSURE_ERR=""
WS_ENSURE_NEW=""
# Set to "1" by the rc-2 (could-not-determine) branch below, cleared at the
# top of every call otherwise: lets callers (launch_issue, #19 review round
# 2 N5) tell "herdr was transiently unreachable/unparseable" apart from a
# genuine config fault, without inventing a second return channel.
WS_ENSURE_TRANSIENT=""
ensure_repo_workspace() {   # <nwo> <path> <old_ws>   (uses CUR_IDX/CUR_NAME)
  local nwo="$1" path="$2" old="$3" field found out new anchor linked rpw_rc
  local new_checkout new_root want_root adopted open_path
  WS_ENSURE_ERR=""
  WS_ENSURE_TRANSIENT=""
  field=$(repo_ws_field "$CUR_IDX" "$nwo")

  found=$(resolve_primary_workspace "$path"); rpw_rc=$?
  if [ "$rpw_rc" -eq 0 ]; then
    repo_set_workspace "$CUR_IDX" "$nwo" "$found" "$old"
    log "board $CUR_NAME: config field $field workspace $old no longer exists; adopted live primary workspace $found for $path"
    if skip_once "ws-recovered:$nwo"; then
      report "config fault, recovered for this run: $field is workspace $old, which no longer exists - herdr destroys a workspace when its last tab closes. Launches for $nwo now use $found, this repo's own live primary workspace for $path. Set $field to $found in the config: a restart still exits 2 on the stale id."
    fi
    WS_ENSURE_NEW="$found"; return 0
  elif [ "$rpw_rc" -eq 2 ]; then
    # Could not determine whether $path already has a live primary
    # workspace (repo_root_for failed, herdr workspace list failed, or its
    # output was not valid JSON): a plain transient failure, NOT license to
    # create - creating here on a false "none exists" reading forks a
    # second workspace onto a checkout that may already have a live one.
    WS_ENSURE_ERR="could not determine whether $path already has a live primary workspace (herdr unreachable or returned unparseable output); not creating a new one"
    WS_ENSURE_TRANSIENT=1
    return 1
  fi

  # `herdr worktree open` (NOT the `worktree create` SKILL.md forbids) is
  # the create path: unlike the old `herdr workspace create`, its response
  # carries a real .result.workspace.worktree — the workspace it opens is
  # one herdr itself records as this checkout's repo workspace, which is
  # what makes it satisfy WSCHECK and resolve_primary_workspace on a later
  # run/board (#19 review round 2, B1). It is also idempotent: run again on
  # an already-open path it returns the SAME existing workspace id instead
  # of forking one, so this call is safe even if resolve_primary_workspace
  # above raced a sibling board's own recovery.
  # Toplevel, not $path verbatim (#19 review round 3, MN1): a config
  # `path` that is a subdirectory of the checkout root passes RCHECK and
  # WSCHECK (both already resolve to the git toplevel), but `herdr
  # worktree open --path <subdir>` itself fails with worktree_not_found -
  # open the toplevel herdr already knows how to match, falling back to
  # $path if it cannot be resolved so the error text below still names the
  # operator's own configured path.
  open_path=$(repo_root_for "$path" 2>/dev/null) || open_path=""
  [ -n "$open_path" ] || open_path="$path"
  out=$(herdr worktree open --cwd "$path" --path "$open_path" --label "$(basename "$path")" --no-focus 2>&1)
  new=$(jq -r '.result.workspace.workspace_id // empty' <<<"$out" 2>/dev/null)
  if [ -z "$new" ]; then
    WS_ENSURE_ERR="herdr worktree open --cwd $path failed: $out"
    return 1
  fi
  # Idempotent per the comment above: a path already open under a live
  # workspace comes back with already_open:true and THAT workspace's id
  # instead of a freshly created one (#19 review round 3, B2) - live-
  # verified that its .result.tab is then the workspace's CURRENTLY ACTIVE
  # tab, not a new one, which may belong to a sibling board's or the
  # operator's own running session. Everything below that assumes
  # exclusive ownership (the anchor rename, closing on a failed check)
  # must not run for this case: adopt it exactly like the
  # resolve_primary_workspace hit above, never touch or destroy it.
  # Every consumer below tests "!= false", not "= true" (#19 review round
  # 4, MINOR-1): herdr 0.9.0 always emits already_open explicitly, but if a
  # future herdr ever dropped or renamed the field, absent/unparseable must
  # fail toward "assume adopted, touch nothing" - the safe direction - not
  # toward "assume freshly created, safe to rename/close".
  adopted=$(jq -r '.result.already_open // empty' <<<"$out" 2>/dev/null)
  # Defensive: a path that BECAME a linked git worktree after startup would
  # give us a linked-worktree workspace, which sweep_orphan_worktrees is
  # entitled to close the registration for (it never removes the checkout).
  # Only an explicit true fails; an absent field is fine.
  linked=$(jq -r '.result.workspace.worktree.is_linked_worktree // empty' <<<"$out" 2>/dev/null)
  if [ "$linked" = "true" ]; then
    if [ "$adopted" != "false" ]; then
      WS_ENSURE_ERR="$path is a linked git worktree, not a primary checkout: herdr returned already-open linked-worktree workspace $new for it - left it untouched, this call does not own it"
    else
      herdr workspace close "$new" >/dev/null 2>&1
      WS_ENSURE_ERR="$path is a linked git worktree, not a primary checkout: herdr opened it as linked-worktree workspace $new (closed it before returning)"
    fi
    return 1
  fi
  # Post-condition (#19 review round 2, N6): `worktree open`'s response
  # carries a real worktree.checkout_path now (the old `workspace create`
  # never surfaced one, so this check was impossible before B1's fix) -
  # confirm it actually resolves to $path's own git toplevel before
  # trusting the new workspace, rather than assuming the id is usable
  # just because herdr returned one.
  new_checkout=$(jq -r '.result.workspace.worktree.checkout_path // empty' <<<"$out" 2>/dev/null)
  new_root=""
  [ -n "$new_checkout" ] && new_root=$(repo_root_for "$new_checkout" 2>/dev/null)
  want_root=$(repo_root_for "$path" 2>/dev/null)
  if [ -z "$new_root" ] || [ -z "$want_root" ] || [ "$new_root" != "$want_root" ]; then
    if [ "$adopted" != "false" ]; then
      WS_ENSURE_ERR="herdr worktree open --cwd $path returned already-open workspace $new but its worktree.checkout_path (${new_checkout:-<none>}) does not resolve to $path's own git toplevel - left it untouched, this call does not own it, not creating a new one"
    else
      herdr workspace close "$new" >/dev/null 2>&1
      WS_ENSURE_ERR="herdr worktree open --cwd $path returned workspace $new but its worktree.checkout_path (${new_checkout:-<none>}) does not resolve to $path's own git toplevel (closed it before returning)"
    fi
    return 1
  fi
  if [ "$adopted" != "false" ]; then
    # Converges with the resolve_primary_workspace hit above rather than
    # the fresh-create path below: herdr found the same live workspace the
    # resolver should have (a transient worktree:null read, a per-candidate
    # repo_root_for failure, or a race with a sibling board's own recovery
    # can all make the resolver miss it). It already has its own tabs -
    # possibly a live session's - so no anchor rename, no ownership claim.
    repo_set_workspace "$CUR_IDX" "$nwo" "$new" "$old"
    log "board $CUR_NAME: config field $field workspace $old no longer exists; adopted live primary workspace $new for $path"
    if skip_once "ws-recovered:$nwo"; then
      report "config fault, recovered for this run: $field is workspace $old, which no longer exists - herdr destroys a workspace when its last tab closes. Launches for $nwo now use $new, this repo's own live primary workspace for $path. Set $field to $new in the config: a restart still exits 2 on the stale id."
    fi
    WS_ENSURE_NEW="$new"; return 0
  fi
  anchor=$(jq -r '.result.tab.tab_id // empty' <<<"$out" 2>/dev/null)
  # herdr's `worktree open` returns .result.workspace (workspace_id plus
  # .worktree = {checkout_path, is_linked_worktree, repo_key, repo_name,
  # repo_root}) and .result.tab (verified live against a fresh checkout,
  # #19 review round 2): the new workspace already HAS a root tab, and
  # naming it is what stops the workspace dying again the moment the last
  # issue tab closes. Never closed by either sweep: its label matches
  # neither sweep_finished_tabs' "^[a-z0-9-]+/issue-[0-9]+:" pattern nor the
  # orphan sweep's linked-worktree + numeric-label check.
  [ -n "$anchor" ] && herdr tab rename "$anchor" "$CUR_NAME workspace anchor - do not close" >/dev/null 2>&1
  repo_set_workspace "$CUR_IDX" "$nwo" "$new" "$old"
  log "board $CUR_NAME: config field $field workspace $old no longer exists and $path has no live primary workspace; opened $new (anchor tab ${anchor:-none})"
  if skip_once "ws-recovered:$nwo"; then
    report "config fault, recovered for this run: $field is workspace $old, which no longer exists - herdr destroys a workspace when its last tab closes, and nothing was holding this one open. Re-opened $path as workspace $new with an anchor tab named $CUR_NAME workspace anchor - do not close; launches for $nwo use it from now on. Set $field to $new in the config (a restart still exits 2 on the stale id) and leave the anchor tab open."
  fi
  WS_ENSURE_NEW="$new"; return 0
}

# Pre-claim gate for a repo previously found unusable: retries the recovery
# (local herdr calls only - no GitHub call, no claim, nothing to release) so
# the board picks itself up without a restart. The recovery's own latched
# report (ensure_repo_workspace's "ws-recovered:<nwo>") already tells the
# operator about the transition with the field name, old id, and new id -
# this does not report again, only clears WSDEAD. rc 1 means "do not claim
# for this repo this cycle".
board_repo_launchable() {   # <nwo>
  local path old
  ws_dead "$CUR_IDX" "$1" || return 0
  path=$(repo_path "$CUR_IDX" "$1") || return 0        # unmapped: leave it to launch_issue's BUG branch
  old=$(repo_workspace "$CUR_IDX" "$1") || return 0
  ensure_repo_workspace "$1" "$path" "$old" || return 1
  ws_dead_clear "$CUR_IDX" "$1"
  return 0
}

# Opens a tab, starts an omp agent, and hands it one specific, already-claimed
# issue. Releases the claim and cleans up the tab if anything fails.
launch_issue() {
  local nwo="$1" num="$2" title="$3"
  local name create_json pane tab start_out start_out_report attempt prompt err_code ws_retry
  local pr_info pr_num pr_branch adopt branch_only item_path item_ws orig_ws

  # Cross-repo dispatch: every downstream call for this item — the tab and
  # its workspace, the PR/branch adoption lookups — runs against ITS OWN
  # repo's checkout and workspace from the board's repo map, never the
  # board's first repo. The backends only emit mapped repos, so a miss here
  # is a watcher bug, not a config gap: release and surface it.
  if ! item_path=$(repo_path "$CUR_IDX" "$nwo") || ! item_ws=$(repo_workspace "$CUR_IDX" "$nwo"); then
    log "issue #$num: BUG: repo $nwo is not in board $CUR_NAME's repo map, releasing claim"
    board_release "$nwo" "$num"
    return 1
  fi
  orig_ws="$item_ws"

  # herdr agent names are global and two boards can both own an issue #12,
  # so the board name namespaces the agent, and the tab label (which the
  # sweep parses back apart) carries "<board>/issue-<n>".
  name="$CUR_NAME-issue-$num"

  # NOTE: the pane id lives at .result.root_pane.pane_id, NOT .result.tab.pane_id
  # or .result.pane_id — those paths look plausible but don't exist, and jq
  # silently returns empty for them. Getting this wrong makes every launch fail
  # after the tab is already created, leaving a real, visible, agent-less tab
  # with no cleanup. Verified against a live `herdr tab create` response; do not
  # change without re-checking the actual response shape.
  err_code=""; ws_retry=0
  while :; do
    create_json=$(herdr tab create --workspace "$item_ws" --cwd "$item_path" --no-focus 2>&1) && break
    # herdr puts its failure JSON on stderr (stdout stays empty), so the 2>&1
    # capture above is exactly one document: .error.code is the class.
    err_code=$(jq -r '.error.code // empty' <<<"$create_json" 2>/dev/null)
    if [ "$err_code" = "workspace_not_found" ]; then
      if [ "$ws_retry" -eq 0 ]; then
        ws_retry=1
        if ensure_repo_workspace "$nwo" "$item_path" "$item_ws"; then
          item_ws=$WS_ENSURE_NEW   # REPOMAP already rewritten; retry once, claim held
          continue
        fi
        # ensure_repo_workspace already set WS_ENSURE_ERR.
      else
        # Second workspace_not_found in the SAME launch, immediately after a
        # successful recovery retry: the workspace we just resolved/created
        # is already gone too. Unrecoverable, not transient - falling
        # through to the generic transient branch here reopens issue #19:
        # the board would claim and release this repo's issues forever,
        # since WSDEAD never gets marked.
        WS_ENSURE_ERR="tab create failed with workspace_not_found again for workspace $item_ws, immediately after a successful recovery to it"
      fi
      if [ "$WS_ENSURE_TRANSIENT" = "1" ]; then
        # rc 2 from resolve_primary_workspace (#19 review round 2, N5):
        # this branch is only reached after herdr's own workspace_not_found
        # already confirmed $orig_ws is gone - the "could not determine"
        # uncertainty is about whether a REPLACEMENT could be resolved this
        # cycle, not about whether the configured workspace still exists.
        # Still fail closed on claiming (ws_dead_mark + release below), but
        # the wording must say what is actually known: gone, not "not
        # confirmed gone" (#19 review round 3, MJ2). The latch key is also
        # its own now, not shared with the permanent-fault branch below
        # (#19 review round 3, MJ1): a shared key meant the first transient
        # blip on a repo silently swallowed every later genuine break
        # report for it, since skip_once never clears.
        log "issue #$num: board $CUR_NAME: workspace $orig_ws for $item_path is confirmed gone (workspace_not_found) and no replacement could be resolved this cycle: $WS_ENSURE_ERR; claim release attempted, retrying automatically"
        if skip_once "ws-transient:$nwo"; then
          report "workspace gone, replacement not yet resolved: herdr confirmed $(repo_ws_field "$CUR_IDX" "$nwo")'s workspace $orig_ws for $item_path no longer exists, but a replacement could not be resolved for $nwo this cycle, likely a transient herdr/git hiccup ($WS_ENSURE_ERR). Issue #$num's claim release was attempted; the board retries the check locally on its own next cycle. If this repeats, update $(repo_ws_field "$CUR_IDX" "$nwo") to a workspace that is $item_path's own live primary workspace."
        fi
      else
        # Permanent, not transient: no workspace can be had for this repo.
        log "issue #$num: board $CUR_NAME: config field $(repo_ws_field "$CUR_IDX" "$nwo") workspace $orig_ws no longer exists and $item_path could not be opened as a workspace: $WS_ENSURE_ERR; claim release attempted, no further claims for $nwo until this is fixed"
        if skip_once "ws-broken:$nwo"; then
          report "config fault, NOT a transient launch failure: $(repo_ws_field "$CUR_IDX" "$nwo") is workspace $orig_ws, which no longer exists, and herdr could not open $item_path as a workspace either ($WS_ENSURE_ERR). Nothing will launch for $nwo on this board until this is fixed: check $item_path still exists and is that repo's own primary checkout, open it as its own herdr workspace, and set that field to the new workspace id. Issue #$num's claim release was attempted and may have failed; further issues for $nwo are now skipped WITHOUT claiming, so the board stops churning; it resumes on its own as soon as $item_path has a usable workspace, or after a restart."
        fi
      fi
      ws_dead_mark "$CUR_IDX" "$nwo"
      board_release "$nwo" "$num"
      return 1
    fi
    # Anything else stays a transient launch failure, carrying herdr's own
    # error code so "retry will fix this" is distinguishable at a glance.
    log "issue #$num: tab create failed${err_code:+ ($err_code)}: $create_json"
    report "issue #$num could not start: tab create failed${err_code:+ ($err_code)}. Claim release was attempted; issue returns to rotation if it succeeded."
    board_release "$nwo" "$num"
    return 1
  done
  pane=$(jq -r '.result.root_pane.pane_id // empty' <<<"$create_json" 2>/dev/null)
  tab=$(jq -r '.result.tab.tab_id // empty' <<<"$create_json" 2>/dev/null)
  if [ -z "$pane" ] || [ -z "$tab" ]; then
    log "issue #$num: tab create returned no pane/tab id, response was: $create_json"
    report "issue #$num could not start: tab create returned no pane id. Claim release was attempted; issue returns to rotation if it succeeded."
    board_release "$nwo" "$num"
    return 1
  fi

  # A freshly created pane is not at its shell prompt yet: `agent start` fails
  # with agent_pane_busy ("not an available shell") for the first second or so.
  # Retry rather than discarding the tab on the first miss.
  attempt=0
  start_out=""
  while [ "$attempt" -lt 10 ]; do
    if start_out=$(herdr agent start "$name" --kind omp --pane "$pane" 2>&1); then
      break
    fi
    case "$start_out" in
      *agent_pane_busy*) attempt=$((attempt + 1)); sleep 1 ;;
      *) attempt=10 ;;
    esac
  done
  if [ "$attempt" -ge 10 ]; then
    log "issue #$num: agent start failed on pane $pane, closing tab $tab and releasing claim: $start_out"
    # Collapsed and bounded for the operator report only (review #20 MN3):
    # $start_out is herdr's raw, possibly multi-line/arbitrary-length stderr
    # capture, and an empty capture must not render as a bare trailing
    # colon. start_out_report collapses it to one line so it slots cleanly
    # mid sentence, truncates it with a marker so the operator can tell
    # there is more in the log, and substitutes a placeholder when empty;
    # the untruncated original is already in the log line above.
    start_out_report=${start_out//$'\n'/ }
    if [ "${#start_out_report}" -gt 300 ]; then
      start_out_report="${start_out_report:0:300}…"
    fi
    [ -z "$start_out_report" ] && start_out_report="(herdr reported no error output)"
    report "issue #$num could not start: agent start failed on pane $pane: $start_out_report. Tab closed; claim release was attempted and issue returns to rotation if it succeeded."
    herdr tab close "$tab" >/dev/null 2>&1
    board_release "$nwo" "$num"
    return 1
  fi

  herdr tab rename "$tab" "$CUR_NAME/issue-$num: $title" >/dev/null 2>&1

  # Hand over any work that already exists for this issue, so the session
  # adopts it instead of starting a second branch and a second PR beside it.
  pr_info=$(existing_pr_for "$nwo" "$num")
  pr_num=$(cut -f1 <<<"$pr_info")
  pr_branch=$(cut -f2 <<<"$pr_info")
  if [ -n "$pr_num" ]; then
    adopt="Work already exists and you are ADOPTING it: open PR #$pr_num on branch $pr_branch. Do not open a new PR and do not start over. Create your worktree from that existing branch, basing it on origin/$pr_branch, then read the issue and that PR (including comments) and the diff against origin/main to establish what is already done, including any uncommitted changes, before you add anything."
  else
    branch_only=$(existing_branch_for "$item_path" "$num")
    if [ -n "$branch_only" ]; then
      adopt="A branch for this issue already exists on origin with no open PR: $branch_only. Inspect it first (git log and diff against origin/main); adopt it and open the draft PR from it if its work is sound, and say so explicitly if you judge it unusable and start fresh instead."
    else
      adopt="No existing branch or PR for this issue: create the worktree and open the draft PR before implementing."
    fi
  fi

  # Mode decides how far a session may take the issue on its own.
  if [ "$CUR_MODE" = "auto" ]; then
    instructions="Autonomous mode is in force. This prompt IS the explicit instruction that next-issue steps 5 to 7 require - do not wait for further approval, and do not ask the operator for routine decisions. In order:
1. If this issue is complex - size:large, cross-cutting, a schema or contract change, or the approach is genuinely unsettled - first run a PLAN per the plan-on-tier skill, then follow it: TIER 2 for a standard plan, TIER 3 when the issue is mission-critical or high-risk - auth and permissions, money, data loss or irreversible operations, schema and migrations, or the board's own control plane. Skip this for small settled work.
2. Implement, and verify proportionately: only what your change touches, no full-project test suite and no repo-wide formatters.
3. Before landing, run a REVIEW per the review-on-tier skill against your finished diff. This is mandatory on every issue. Round 1 is that first full review pass; each further full re-review pass counts as the next round. Run rounds 1 and 2 at this issue's plan tier (TIER 2 if no plan was run), escalating to TIER 3 for round 3 and any further round. When rounds 1-2 ran below tier 3, round 3 is a new tier-3 subagent with no memory of the earlier rounds, so hand it the prior rounds' findings and what you changed in response before it reviews. Fix every real finding, re-review if you changed anything material, and state in your report what it raised and what you did about each item.
4. If the issue carries mgr:manual-approve, mark the PR ready and stop there - do NOT merge it. Otherwise land it yourself: mark the PR ready, merge it squashed, $UNCLAIM_PHRASE.
5. Then stop, completely. Remove your worktree, post your final report (noting explicitly if the PR is waiting on mgr:manual-approve rather than landed), and end your turn. Landing it, or leaving it ready for approval, is the finish line: do NOT review the landed commit, do NOT deploy or redeploy anything, do NOT update docs or changelogs, do NOT read AGENTS.md looking for follow-up chores, and do NOT pick up another issue. If you believe something genuinely remains, say so in your report and stop anyway - the board decides what happens next, not you."
  else
    instructions="Implement and verify proportionately: only what your change touches, no full-project test suite and no repo-wide formatters. Then stop and report. Do not run gh pr ready, do not merge, do not close the issue, and do not remove the worktree - the operator instructs ready, land and done in this tab when ready."
  fi

  # Keep this prompt free of backticks and dollar signs beyond these expansions:
  # it is passed straight through, and shell-special text in it has bitten us.
  prompt="Use the next-issue skill to own issue #$num ($title). The board watcher has already selected and claimed it $CLAIM_PHRASE, so skip the selection and claiming step. $adopt Work strictly inside your own worktree, never the primary checkout. Note the local main ref in the primary checkout may be stale, so always compare against origin/main.

$instructions"

  if ! herdr agent prompt "$name" "$prompt" \
        --wait --until working --until blocked --timeout 20000 >/dev/null 2>&1; then
    log "issue #$num: prompt not confirmed on tab $tab; leaving tab and claim in place for manual inspection"
    report "issue #$num: agent started on tab $tab but did not confirm the prompt. Tab and claim left in place - needs a look."
    return 1
  fi

  log "issue #$num launched: $title (pane $pane tab $tab)"
  report "launched issue #$num ($title) on tab $tab. $CLAIMED_REPORT; that session owns it from here."
  return 0
}

# ---------------------------------------------------------------------------
# service_board <i>: the per-board error boundary. The whole cycle body for
# one board runs inside it, against that board's context and state, and it
# RETURNS on failure — it never exits — so a broken board (expired token,
# deleted repo, network) can neither break the main loop nor the boards
# after it.
# ---------------------------------------------------------------------------

# Loads board <i>'s config into the CUR_* working set the backends and
# launch path read, and picks the mode-dependent wording for handout prompts
# and reports; the repo-mode strings are the original text, byte for byte.
board_ctx_load() {
  local i="$1"
  CUR_IDX=$i
  bv "$i" REPOMAP; CUR_REPOMAP=$bvv
  bv "$i" NAME; CUR_NAME=$bvv
  bv "$i" KIND; CUR_KIND=$bvv
  bv "$i" REPO; CUR_REPO=$bvv
  bv "$i" PATH; CUR_PATH=$bvv
  bv "$i" WS; CUR_WS=$bvv
  bv "$i" CONC; CUR_CONC=$bvv
  bv "$i" MODE; CUR_MODE=$bvv
  bv "$i" OWNER; CUR_OWNER=$bvv
  bv "$i" NUMBER; CUR_NUMBER=$bvv
  bv "$i" PROJECT_ID; CUR_PROJECT_ID=$bvv
  bv "$i" STATUS_FIELD_ID; CUR_STATUS_FIELD_ID=$bvv
  bv "$i" OPT_TODO; CUR_OPT_TODO=$bvv
  bv "$i" OPT_IN_PROGRESS; CUR_OPT_IN_PROGRESS=$bvv
  bv "$i" OPT_DONE; CUR_OPT_DONE=$bvv
  if [ "$CUR_KIND" = "project" ]; then
    CLAIM_PHRASE="on the project board (its card's Status is In progress; Status is watcher-owned - never edit it)"
    UNCLAIM_PHRASE="close the issue - the board watcher moves the project card to Done itself"
    CLAIMED_REPORT="Moved its card to In progress"
    CLAIM_NOUN="the board slot"
  else
    CLAIM_PHRASE="with mgr:in-flight"
    UNCLAIM_PHRASE="close the issue and remove mgr:in-flight"
    CLAIMED_REPORT="Claimed mgr:in-flight"
    CLAIM_NOUN="mgr:in-flight"
  fi
}

board_state_load() {
  local i="$1"
  bv "$i" PREV_INFLIGHT; prev_inflight=$bvv
  bv "$i" FIRST; first_cycle=$bvv
  bv "$i" FLIGHT_CACHE; FLIGHT_CACHE=$bvv
  bv "$i" FLIGHT_SEEN_DEPART; FLIGHT_SEEN_DEPART=$bvv
  bv "$i" DONE_SYNCED; PROJECT_DONE_SYNCED=$bvv
}

board_state_save() {
  local i="$1"
  bset "$i" PREV_INFLIGHT "$prev_inflight"
  bset "$i" FIRST "$first_cycle"
  bset "$i" FLIGHT_CACHE "$FLIGHT_CACHE"
  bset "$i" FLIGHT_SEEN_DEPART "$FLIGHT_SEEN_DEPART"
  bset "$i" DONE_SYNCED "$PROJECT_DONE_SYNCED"
}

# One board's whole cycle. Any fetch failure logs the raw error and returns
# 1 BEFORE the state it could not observe is acted on: a failed in-flight
# fetch must not read as "everything departed", and a failed ready fetch
# must not read as an idle board — so no departure diff, no claim, no
# release, no launch happens on the failure path.
service_board_cycle() {
  # Repos resolved (either way) this cycle for want of a workspace: keeps
  # both the recovery attempt and the skip log to one per repo instead of
  # one per ready issue (issue #19 M3).
  CYCLE_WS_SKIP=""
  CYCLE_WS_OK=""
  if ! board_load; then
    log "board $CUR_NAME: in-flight fetch failed: $(cat "$ERRFILE")"
    return 1
  fi
  inflight=$(board_inflight) || return 1
  count=0
  [ -n "$inflight" ] && count=$(wc -l <<<"$inflight" | tr -d ' ')
  free=$(( CUR_CONC - count ))

  # Refresh this board's contribution to the cross-board dedupe union with
  # the fresh fetch, so boards serviced later this same cycle already see
  # anything just observed (or just claimed by someone else) in flight here.
  [ -n "$inflight" ] && CYCLE_SEEN=$(printf '%s\n%s' "$CYCLE_SEEN" "$inflight" | sort -u)

  # Anything that left flight since the last cycle: landed, closed, or had its
  # claim dropped by someone else. Worth surfacing — a session landing its own
  # issue is otherwise invisible from here. Rows are "<nwo>#<num>" keys, so a
  # cross-repo board's repos can reuse issue numbers without colliding.
  if [ "$first_cycle" -eq 0 ] && [ "$prev_inflight" != "$inflight" ]; then
    while read -r gone; do
      [ -z "$gone" ] && continue
      g_nwo="${gone%%#*}"
      g_num="${gone##*#}"
      state=$(gh issue view "$g_num" -R "$g_nwo" --json state --jq '.state' 2>/dev/null)
      # Reconcile the finished issue's board state: repo mode strips a stale
      # mgr:in-flight, project mode moves the card to Done.
      [ "$state" = "CLOSED" ] && board_finish "$g_nwo" "$g_num"
      # Departure resets the age clock's memory: if the issue re-enters
      # flight, the first-sight path re-reads GitHub - including, in repo
      # mode, the timeline lookup that detects a re-claimed issue's new
      # start. That lookup now runs exactly when it can change the answer.
      flight_cache_drop "$gone"
      grep -qxF "$gone" <<<"$FLIGHT_SEEN_DEPART" \
        || FLIGHT_SEEN_DEPART=$(printf '%s\n%s' "$FLIGHT_SEEN_DEPART" "$gone")
      # A card a human dragged out of In progress lands here too: it simply
      # left flight, this report covers it, and the human's move stands.
      report "issue #$g_num left flight (issue is now ${state:-unknown}). Slot freed."
    done <<<"$(comm -23 <(printf '%s\n' "$prev_inflight") <(printf '%s\n' "$inflight") 2>/dev/null)"
  fi
  prev_inflight="$inflight"
  first_cycle=0

  # Reconcile finished tabs every cycle, not just on the departure pass: a
  # just-closed issue usually still has its worktree while the session tears
  # down, so it gets swept on a later pass.
  sweep_finished_tabs

  # Reap stray per-worktree herdr workspaces from the old (now-removed)
  # per-issue-workspace mechanism, or from a stray hand/tool `herdr worktree
  # create` — see sweep_orphan_worktrees for the exact reap predicate. Local
  # herdr/git calls only; no GitHub calls, so it never affects the rate
  # limit accounting below.
  sweep_orphan_worktrees

  # Long-running-issue notices: once per whole hour an issue has been
  # in-flight, never more than once for the same hour - even across watcher
  # restarts, since the durable clock is each issue's marker comment, not a
  # local file. FLIGHT_CACHE mirrors that record in memory (see its comment):
  # GitHub is read once per flight period, written once per hour boundary.
  #
  # The scan itself runs only every AGE_SCAN_SECONDS per board (cursor in
  # BOARD_<i>_AGE_NEXT, offset per board at startup): the notices are hourly,
  # so scanning every poll bought nothing but first-sight reads N times
  # sooner. Departures still drop cache rows every cycle above, so a
  # re-claimed issue's next scan re-reads GitHub exactly as before.
  now_epoch=$(date -u +%s)
  bv "$CUR_IDX" AGE_NEXT
  if [ "$now_epoch" -ge "$bvv" ]; then
    bset "$CUR_IDX" AGE_NEXT $((now_epoch + AGE_SCAN_SECONDS))
    while read -r key; do
      [ -z "$key" ] && continue
      f_nwo="${key%%#*}"
      num="${key##*#}"

      row=$(flight_cache_row "$key")
      if [ -n "$row" ]; then
        # Seen in flight before, and not departed since: serve from memory.
        IFS=$'\t' read -r _ start_iso start_epoch hours_reported comment_id <<<"$row"
        need_write=0
      else
        # First sight of this flight period: read the durable record back.
        comment_id="" start_iso="" hours_reported=0
        marker=$(age_comment_for "$f_nwo" "$num")
        [ -n "$marker" ] && IFS=$'\t' read -r comment_id start_iso hours_reported <<<"$marker"

        # The mgr:in-flight timeline is the source of truth for when the
        # CURRENT flight period began. A marker comment surviving from an
        # earlier period (the issue left flight and was later re-claimed)
        # would otherwise report a bogus multi-day duration, so a labeling
        # event newer than our recorded start resets the clock. Project mode
        # has no labeling events to consult: there, a re-entry observed by
        # this process resets the clock to now, and after a restart the
        # marker's own recorded start stands.
        latest_iso=""
        if [ "$CUR_KIND" = "repo" ]; then
          latest_iso=$(fetch_start_iso "$f_nwo" "$num")
        elif grep -qxF "$key" <<<"$FLIGHT_SEEN_DEPART"; then
          latest_iso=$(date -u +%FT%TZ)
        fi
        need_write=0
        [ -z "$comment_id" ] && need_write=1
        if [ -z "$start_iso" ] || { [ -n "$latest_iso" ] && [ "$latest_iso" \> "$start_iso" ]; }; then
          start_iso="${latest_iso:-$(date -u +%FT%TZ)}"
          hours_reported=0
          need_write=1
        fi
        start_epoch=$(iso_to_epoch "$start_iso") || start_epoch=$now_epoch
        [ -z "$start_epoch" ] && start_epoch=$now_epoch
      fi

      elapsed_hours=$(( (now_epoch - start_epoch) / 3600 ))
      if [ "$elapsed_hours" -gt "$hours_reported" ]; then
        title=$(title_for "$f_nwo" "$num")
        log "issue #$num has been in flight for ${elapsed_hours}h: $title"
        report "issue #$num has been in flight for ${elapsed_hours}h: $title."
        hours_reported=$elapsed_hours
        need_write=1
      fi

      if [ "$need_write" -eq 1 ]; then
        if [ -n "$comment_id" ]; then
          update_flight_comment "$f_nwo" "$comment_id" "$(flight_comment_body "$start_iso" "$hours_reported")"
        else
          comment_id=$(create_flight_comment "$f_nwo" "$num" "$(flight_comment_body "$start_iso" "$hours_reported")")
        fi
        flight_cache_put "$key" "$start_iso" "$start_epoch" "$hours_reported" "$comment_id"
      elif [ -z "$row" ]; then
        flight_cache_put "$key" "$start_iso" "$start_epoch" "$hours_reported" "$comment_id"
      fi
    done <<<"$inflight"
  fi

  if ! ready_list=$(board_ready); then
    log "board $CUR_NAME: ready fetch failed: $(cat "$ERRFILE")"
    return 1
  fi
  ready_n=0
  [ -n "$ready_list" ] && ready_n=$(wc -l <<<"$ready_list" | tr -d ' ')

  launch=$free
  [ "$ready_n" -lt "$launch" ] && launch=$ready_n
  [ "$launch" -lt 0 ] && launch=0

  log "in-flight=$count free=$free ready=$ready_n launching=$launch"

  # Fetch + reconcile herdr agent list whenever there is ready work to
  # gate OR this board holds any AGENTBUSY latch that might need
  # clearing (review #20 round 4 BL1). Reconciling only inside the
  # ready-row loop below left a latch's clear path reachable ONLY when
  # the per-issue loop actually reached that exact row - but the
  # cycle-top CYCLE_SEEN seed (see the main loop's "Cross-board dedupe
  # union for THIS cycle") puts every latched "<nwo>#<num>" into
  # CYCLE_SEEN before ANY board runs, so the owning board's own
  # per-issue loop dedupe-skips that row at the very first check below,
  # before ever reaching the agent-busy check that used to clear it -
  # starving the issue forever, on every board, once the blocking
  # session exits, until a watcher restart. A board at full concurrency
  # (launch=0) never even entered the old fetch block, so its stale
  # latch could never clear at all while still poisoning CYCLE_SEEN for
  # siblings. Reconciling here, independent of free capacity and of the
  # per-issue loop, keeps the clear path reachable in both cases; a
  # one-cycle relaunch lag after clearing is expected and fine (this
  # cycle's CYCLE_SEEN seed already predates the clear).
  bv "$CUR_IDX" AGENTBUSY
  agentbusy_snapshot=$bvv
  if [ "$launch" -gt 0 ] || [ -n "$agentbusy_snapshot" ]; then
    # agent_list_ok carries the fetch outcome explicitly rather than
    # being inferred from live_agent_names being empty (review #20
    # MJ1): "fetch succeeded, zero live agents" and "fetch failed" are
    # both empty-string cases and must not be conflated, or a failed
    # fetch reads as proof no agent is live and wrongly clears every
    # currently-latched agent_busy mark, re-arming the report and the
    # claim/release churn on every herdr flap. A failed fetch is NOT
    # fatal to this cycle's launches — it just means this cycle runs
    # without the extra guard, exactly like every cycle before #20, so
    # one bad fetch costs at most one ordinary agent-start-failure-and-
    # release, never a new stuck loop.
    agent_list_out=$(herdr agent list 2>/dev/null)
    agent_list_rc=$?
    if [ "$agent_list_rc" -eq 0 ] && jq -e . >/dev/null 2>&1 <<<"$agent_list_out"; then
      agent_list_ok=1
      live_agent_names=$(jq -r '.result.agents[]? | (.name // "")' <<<"$agent_list_out")
    else
      log "board $CUR_NAME: herdr agent list failed or returned invalid JSON — launching this cycle without the already-live-agent check"
      if skip_once "agent-list-failed-launch-gate"; then
        report "herdr agent list failed or returned invalid JSON — launching without the check that skips relaunching an issue whose own agent is still live (#20's guard). If this repeats, the old per-cycle claim/release loop for such an issue can recur; a transient herdr fault is the likely cause."
      fi
    fi
    if [ "$agent_list_ok" -eq 1 ] && [ -n "$agentbusy_snapshot" ]; then
      while IFS= read -r busy_key; do
        [ -z "$busy_key" ] && continue
        busy_num=${busy_key##*#}
        [ -z "$busy_num" ] && continue
        grep -qxF "$CUR_NAME-issue-$busy_num" <<<"$live_agent_names" || agent_busy_clear "$CUR_IDX" "$busy_key"
      done <<<"$agentbusy_snapshot"
    fi
  fi

  if [ "$launch" -gt 0 ]; then
    launched=0
    while IFS=$'\t' read -r nwo num title; do
      [ "$launched" -ge "$launch" ] && break
      [ -z "$num" ] && continue
      # Cross-board dedupe: an issue legitimately sitting on two boards (a
      # label board and a project board, say) must still run only once,
      # and a ready issue latched agent_busy on ANY board (its own
      # AGENTBUSY seeded into CYCLE_SEEN at cycle-top, or another board's
      # right here in this same cycle) must not be claimed either. First
      # in-flight sighting, first claim, or first agent-busy latch this
      # cycle wins; the loser skips quietly - a log line, not an operator
      # report.
      if grep -qxF "$nwo#$num" <<<"$CYCLE_SEEN"; then
        log "issue #$num ($nwo): already accounted for this cycle (in flight elsewhere, or a still-latched live-agent skip), skipping"
        continue
      fi
      # An issue whose own launch-target agent name — "$CUR_NAME-issue-$num",
      # built identically to launch_issue's own $name — is still a live
      # herdr agent means a session holding that exact name has not
      # exited (normally this issue's own prior session; on a project
      # board spanning repos the same board+number can instead belong to
      # another repo's issue #$num, since the name is not repo-qualified
      # — the report below hedges accordingly, review #20 MN2). herdr
      # agent names are global and unique, so claiming and launching into
      # a name that is still taken only fails agent start, releases the
      # claim, and re-claims it again next cycle forever (#20). Skip
      # WITHOUT claiming instead, and also fold this row into CYCLE_SEEN
      # (review #20 MJ2): otherwise a sibling board sharing this repo
      # sees the issue as un-owned (it is by definition not mgr:in-flight
      # here — its prior session already dropped that on landing) and
      # launches a second, concurrent session under its OWN board-name on
      # the same issue and worktree. agent_busy latches the operator
      # report to once per occurrence rather than every cycle — gated on
      # agent_list_ok so a failed fetch (empty live_agent_names for the
      # wrong reason) can never look like a match. The latch is cleared
      # by the reconcile pass above this loop, not here (review #20
      # round 4 BL1): clearing in-loop was only reachable when the
      # per-issue loop got to this exact row, which the cycle-top
      # CYCLE_SEEN seed (see above) prevents from cycle 2 of an
      # occurrence onward.
      agent_name="$CUR_NAME-issue-$num"
      if [ "$agent_list_ok" -eq 1 ] && grep -qxF "$agent_name" <<<"$live_agent_names"; then
        CYCLE_SEEN=$(printf '%s\n%s' "$CYCLE_SEEN" "$nwo#$num")
        if ! agent_busy "$CUR_IDX" "$nwo#$num"; then
          agent_busy_mark "$CUR_IDX" "$nwo#$num"
          log "issue #$num: agent $agent_name is already live; skipping without claiming"
          report "issue #$num: skipped without claiming - a live herdr agent named $agent_name already holds this launch name (herdr agent names are global and unique). This is normally a still-running session for this exact issue: no action needed, it self-heals and this issue launches automatically once that session exits and frees the name. If that session has already finished, close its tab to free the name now. On a multi-repo project board the name can instead belong to a different repo's issue #$num sharing the same board+number - free it without disturbing that other session via herdr agent rename $agent_name --clear."
        else
          log "issue #$num: agent $agent_name still live, already reported; skipping without claiming"
        fi
        continue
      fi
      # A repo whose workspace is gone and cannot be re-established gets no
      # claim at all: claiming an issue we cannot launch just releases it
      # again next cycle forever (issue #19), burning two label writes per
      # ready issue per cycle and leaving the board looking healthy. The
      # retry inside board_repo_launchable does real herdr work (workspace
      # list, a git rev-parse per candidate, maybe workspace create), so
      # CYCLE_WS_SKIP/CYCLE_WS_OK are checked FIRST, before ever calling it
      # again for this repo this cycle: a dead repo with N ready issues
      # attempts recovery once per cycle, not N times, and once recovered
      # this cycle the remaining ready issues fall straight through to the
      # claim below without re-attempting recovery.
      if grep -qxF "$nwo" <<<"$CYCLE_WS_SKIP"; then
        continue
      fi
      if grep -qxF "$nwo" <<<"$CYCLE_WS_OK" && ws_dead "$CUR_IDX" "$nwo"; then
        # A later launch_issue in this SAME cycle marked the repo dead
        # (ws_dead_mark) after this gate had already OK'd it this cycle
        # (#19 review round 2, N4): a stale CYCLE_WS_OK must not keep
        # overriding a fresher WSDEAD state, or the remaining ready rows
        # for this repo bypass the gate and each claim/release/recover
        # again before the gate catches up next cycle.
        CYCLE_WS_SKIP=$(printf '%s\n%s' "$CYCLE_WS_SKIP" "$nwo")
        continue
      fi
      if ! grep -qxF "$nwo" <<<"$CYCLE_WS_OK"; then
        if board_repo_launchable "$nwo"; then
          CYCLE_WS_OK=$(printf '%s\n%s' "$CYCLE_WS_OK" "$nwo")
        else
          CYCLE_WS_SKIP=$(printf '%s\n%s' "$CYCLE_WS_SKIP" "$nwo")
          log "board $CUR_NAME: no usable herdr workspace for $nwo ($WS_ENSURE_ERR), not claiming its issues this cycle"
          continue
        fi
      fi
      if ! board_claim "$nwo" "$num"; then
        claim_diag=$(board_mutation_diag)
        claim_state="unknown"
        [ "$CUR_KIND" = "repo" ] && claim_state=$(repo_board_claim_state "$nwo" "$num")
        case "$claim_state" in
          present)
            # A present failed claim may have consumed this board's slot even
            # though no session was launched. Reserve the slot and the issue
            # across the rest of this cycle; do not blindly remove a claim
            # whose owner cannot be identified.
            CYCLE_SEEN=$(printf '%s\n%s' "$CYCLE_SEEN" "$nwo#$num")
            launched=$((launched + 1))
            log "issue #$num: claim command failed but $CLAIM_NOUN is present; no session launched, slot reserved to avoid duplicate dispatch: $claim_diag"
            report "issue #$num: could not claim $CLAIM_NOUN: $claim_diag. Read-back found the claim present, so no session was launched by this attempt and the issue was reserved for the rest of this cycle. Ownership remains unresolved; the retained claim may consume capacity until an owner finishes or the documented board ownership audit reconciles it."
            ;;
          absent)
            log "issue #$num: claim failed and read-back found $CLAIM_NOUN absent: $claim_diag"
            report "issue #$num: could not claim $CLAIM_NOUN: $claim_diag. Read-back found no claim; skipped this cycle and normal watcher recovery will retry."
            ;;
          *)
            # Unknown mutation state is also fail-closed: the command may
            # have reached GitHub, so reserve both admission controls.
            CYCLE_SEEN=$(printf '%s\n%s' "$CYCLE_SEEN" "$nwo#$num")
            launched=$((launched + 1))
            log "issue #$num: claim failed and read-back could not confirm $CLAIM_NOUN; no session launched, slot reserved to avoid duplicate dispatch: $claim_diag"
            report "issue #$num: could not claim $CLAIM_NOUN: $claim_diag. Read-back could not confirm state; no session was launched by this attempt and the issue was reserved for the rest of this cycle. Ownership remains unresolved and the claim may consume capacity if the mutation succeeded; use the documented board ownership audit rather than replaying the mutation blindly."
            ;;
        esac
        continue
      fi
      CYCLE_SEEN=$(printf '%s\n%s' "$CYCLE_SEEN" "$nwo#$num")
      launch_issue "$nwo" "$num" "$title" || true
      launched=$((launched + 1))
    done <<<"$ready_list"
  fi
  return 0
}

# Classifies the raw stderr left in $ERRFILE into a short operator-readable
# class for the latched degraded report; the full raw error is already in
# the watcher log from the failing cycle itself.
err_class() {
  local e
  e=$(cat "$ERRFILE" 2>/dev/null)
  case "$e" in
    *"missing required scopes"*|*"Bad credentials"*|*uthentication*|*"HTTP 401"*|*"HTTP 403"*) printf 'auth failure\n' ;;
    *"rate limit"*|*"HTTP 429"*) printf 'rate limited\n' ;;
    *"Could not resolve"*|*"no such host"*|*"connection refused"*|*"dial tcp"*|*imeout*|*"TLS"*) printf 'network failure\n' ;;
    *) printf 'fetch failure\n' ;;
  esac
}

service_board() {
  local i="$1" rc fails skip
  bv "$i" FAILS; fails=$bvv
  # Cheap fixed backoff: after 5 consecutive fetch failures the board is
  # serviced only every 10th cycle — failed calls still burn rate limit and
  # the raw error is already in the log. Any success resets the count.
  if [ "$fails" -ge 5 ]; then
    bv "$i" BACKOFF; skip=$bvv
    if [ "$skip" -lt 9 ]; then
      bset "$i" BACKOFF $((skip + 1))
      return 0
    fi
    bset "$i" BACKOFF 0
  fi
  board_ctx_load "$i"
  board_state_load "$i"
  service_board_cycle
  rc=$?
  board_state_save "$i"
  # Latched degraded/recovered reports: fired on state ENTRY (the 3rd
  # consecutive failed cycle) and on state EXIT (the first success after),
  # never repeated while the state holds. The every-cycle raw error stays
  # log-only.
  if [ "$rc" -ne 0 ]; then
    bset "$i" FAILS $((fails + 1))
    [ $((fails + 1)) -eq 3 ] && report "degraded: $(err_class)"
  else
    [ "$fails" -ge 3 ] && report "recovered"
    [ "$fails" -ne 0 ] && bset "$i" FAILS 0
  fi
  return "$rc"
}

b=0
while [ "$b" -lt "$NBOARDS" ]; do
  board_ctx_load "$b"
  log "watcher started: workspace=$CUR_WS concurrency=$CUR_CONC poll=${POLL_SECONDS}s mode=$CUR_MODE"
  if [ "$CUR_KIND" = "project" ]; then
    log "board mode: project $CUR_OWNER/$CUR_NUMBER - the Status single-select is the state machine; labels are not board state"
  fi
  b=$((b + 1))
done

# ONE consolidated startup report listing every board — N per-board
# messages would wake the operator session N times to say the same thing.
report_raw "started: $NBOARDS board(s), polling every ${POLL_SECONDS}s.$BOARDS_SUMMARY
Supervised boards stop after pushing - you instruct ready/land/done in each issue tab. Auto boards plan (tier 2, tier 3 for high-risk work), implement, run a mandatory review at the plan tier for rounds 1-2 (tier 2 if no plan ran), escalating to tier 3 from round 3, then land on their own; mgr:manual-approve still gates those merges. Launches, departures, hourly age notices and failures are reported here per board."

# The operator's total load, as one visible number: concurrency summed across
# the config, and the steady-state gh request rate (repo mode: in-flight +
# ready fetches; project mode: item-list + one open-issue list per mapped
# repo; launches, sweeps and the every-600s flight-age scans come on top).
TOTAL_CONC=0
CALLS_PER_CYCLE=0
b=0
while [ "$b" -lt "$NBOARDS" ]; do
  bv "$b" CONC
  TOTAL_CONC=$((TOTAL_CONC + bvv))
  bv "$b" KIND
  if [ "$bvv" = "project" ]; then
    bv "$b" REPOMAP
    CALLS_PER_CYCLE=$((CALLS_PER_CYCLE + 1 + $(wc -l <<<"$bvv" | tr -d ' ')))
  else
    CALLS_PER_CYCLE=$((CALLS_PER_CYCLE + 2))
  fi
  b=$((b + 1))
done
EST_RPH=$((CALLS_PER_CYCLE * 3600 / POLL_SECONDS))
log "budget: $NBOARDS board(s), total concurrency=$TOTAL_CONC, ~$EST_RPH baseline gh requests/hour at poll=${POLL_SECONDS}s"
if [ "$EST_RPH" -gt 3000 ]; then
  log "WARNING: ~$EST_RPH gh requests/hour is above 3000/h; raise poll_seconds"
fi

while true; do
  # Cross-board dedupe union for THIS cycle: every board's last-observed
  # in-flight "<nwo>#<num>" keys, PLUS every board's own currently-latched
  # AGENTBUSY keys (review #20 round 3 MJ5). PREV_INFLIGHT alone is not
  # enough for a live-agent-blocked issue: it is by definition NOT in
  # flight (its prior session already dropped mgr:in-flight on landing),
  # so without this the within-cycle CYCLE_SEEN append the launch loop's
  # skip branch does (see there) protects only sibling boards serviced
  # AFTER the owning board in THIS cycle, and evaporates at the very next
  # cycle's reset below — a sibling board serviced first, or serviced on
  # any later cycle, would see the issue as unclaimed and launch a SECOND
  # concurrent session beside the still-live one. AGENTBUSY's lines are
  # already exact "<nwo>#<num>" CYCLE_SEEN keys, so folding them in here
  # closes that gap for every cycle where the owning board has latched
  # the issue at least once; only a genuine one-poll race (sibling claims
  # before the owning board has ever seen the issue ready) remains, the
  # same class as the pre-existing cross-board claim race board_claim
  # already arbitrates. Each board refreshes its own contribution when
  # its fresh fetch lands, and claims append immediately (see the launch
  # loop) — the only cross-board coupling in the watcher, read-only apart
  # from those insertions.
  CYCLE_SEEN=""
  CYCLE_WS_SKIP=""
  CYCLE_WS_OK=""
  b=0
  while [ "$b" -lt "$NBOARDS" ]; do
    bv "$b" PREV_INFLIGHT
    [ -n "$bvv" ] && CYCLE_SEEN=$(printf '%s\n%s' "$CYCLE_SEEN" "$bvv")
    bv "$b" AGENTBUSY
    [ -n "$bvv" ] && CYCLE_SEEN=$(printf '%s\n%s' "$CYCLE_SEEN" "$bvv")
    b=$((b + 1))
  done

  b=0
  while [ "$b" -lt "$NBOARDS" ]; do
    service_board "$b" || true
    b=$((b + 1))
  done

  operation_maintenance

  # Backgrounded sleep + wait, so TERM/INT is handled immediately. A plain
  # `sleep "$POLL_SECONDS"` defers the trap until the sleep finishes, which
  # makes a stop take up to a full poll interval and invites a hard kill.
  sleep "$POLL_SECONDS" &
  wait $!
done
