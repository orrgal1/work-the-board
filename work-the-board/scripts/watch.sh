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
#         auto — sessions plan (tier 2, if complex), implement, run a mandatory
#         tier 2 review, then land and finish on their own. mgr:manual-approve
#         still gates the merge.
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

# ---------------------------------------------------------------------------
# Config: --config file, or the positional form synthesized into the exact
# equivalent one-board config. Parsed and validated in ONE jq pass that
# emits TSV rows: ERR (validation failure), CFG (globals), BOARD (one per
# board, in file order), RCHECK (one per repo/path pair to verify against
# the filesystem). Any ERR row aborts with exit 2 before the first cycle —
# a bad path discovered lazily is a silently parked board.
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
      | ["RCHECK", $b, .repo, .path] | @tsv)
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
  bset "$i" SKIP 0
  # Wave-2 seam: cursor for the slow flight-age schedule. Unused in wave 1.
  bset "$i" AGE_NEXT 0
  # Wave-2 seam: the full per-board repo map, for cross-repo project boards.
  # Wave 1 launches only from entry 0 (CUR_REPO/CUR_PATH/CUR_WS below) and
  # skips project items belonging to any other repo.
  bset "$i" REPOMAP "$(jq -c --argjson i "$i" \
    '.boards[$i] | if .kind == "repo"
       then [{repo: .repo, path: .path, workspace: .workspace}]
       else .repos end' <<<"$CONFIG_JSON")"
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

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# Fetch failures land their raw stderr here so the caller can log it. One
# file, created once, read only on the failure path.
ERRFILE=$(mktemp "${TMPDIR:-/tmp}/work-the-board-err.XXXXXX") || exit 1
trap 'rm -f "$ERRFILE"' EXIT

# Reports a material change to the board session so the operator sees it without
# reading the log. Only state changes are reported — launches, failures, released
# claims — never idle cycles, or the board session gets woken every poll for
# nothing. Fire-and-forget: never --wait here, or a busy board session would
# stall the whole loop.
report() {
  [ -n "$REPORT_TARGET" ] || return 0
  herdr agent prompt "$REPORT_TARGET" "board watcher: $1" >/dev/null 2>&1 || true
}

trap 'log "watcher stopping"; report "stopped."; exit 0' TERM INT

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
def emit_ready: sort_by(.prio, .number) | .[] | "\(.number)\t\(.title)";
'

READY_FILTER="$READY_RULES"'
[.[] | .number] as $open
| [ .[]
    | select(((label_names | (index("mgr:in-flight") or index("mgr:hold"))) or is_research) | not)
    | select(unblocked($open))
    | { number, title, prio: prio }
  ]
| emit_ready
'

# --- repo backend: the original mgr:* label state machine -------------------

repo_board_load() {
  inflight_data=$(gh issue list -R "$CUR_REPO" --state open --label mgr:in-flight --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>"$ERRFILE") || return 1
}

# Prints ready issues, one per line, as "<number><TAB><title>".
repo_board_ready() {
  local data
  data=$(gh issue list -R "$CUR_REPO" --state open --json number,title,labels,body --limit 200 2>"$ERRFILE") || return 1
  [ -z "$data" ] && return 0
  jq -r "$READY_FILTER" <<<"$data" 2>/dev/null
}

repo_board_claim() { gh issue edit "$1" -R "$CUR_REPO" --add-label mgr:in-flight >/dev/null 2>&1; }
repo_board_release() { gh issue edit "$1" -R "$CUR_REPO" --remove-label mgr:in-flight >/dev/null 2>&1; }

# A closed issue still carrying mgr:in-flight is pure residue: the label no
# longer gates anything (capacity only counts open issues) but it is exactly
# what accumulates into a board nobody can read. Sessions sometimes close the
# issue and exit before dropping it. No judgment needed once the issue is
# closed, so strip it.
repo_board_finish() {
  if gh issue view "$1" -R "$CUR_REPO" --json labels --jq '[.labels[].name] | index("mgr:in-flight") // empty' 2>/dev/null | grep -q .; then
    gh issue edit "$1" -R "$CUR_REPO" --remove-label mgr:in-flight >/dev/null 2>&1 \
      && log "issue #$1: stripped stale mgr:in-flight from a closed issue"
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
# state, which is why board_load also fetches $open, this repo's open issue
# numbers. Draft items, PRs, and issues of other repos are skipped — the
# cross-repo dispatch through BOARD_<i>_REPOMAP is wave 2; until then a
# project board acts on its repos[0] entry only.
PROJECT_NORMALIZE='
[ .items[]?
  | select((.content.type // "") == "Issue" and (.content.repository // "") == $repo)
  | .content.number as $n
  | { number: $n,
      title: (.content.title // ""),
      item: .id,
      status: (.status // ""),
      state: (if ($open | index($n)) != null then "OPEN" else "CLOSED" end),
      labels: (.labels // []),
      body: (.content.body // "") } ]
'

project_items="[]"
project_open_numbers="[]"

project_board_load() {
  local raw
  raw=$(gh project item-list "$CUR_NUMBER" --owner "$CUR_OWNER" --format json --limit 200 2>"$ERRFILE") || return 1
  project_open_numbers=$(gh issue list -R "$CUR_REPO" --state open --json number --limit 200 --jq '[.[].number]' 2>"$ERRFILE") || return 1
  [ -z "$project_open_numbers" ] && project_open_numbers="[]"
  project_items=$(jq -c --arg repo "$CUR_REPO" --argjson open "$project_open_numbers" "$PROJECT_NORMALIZE" <<<"$raw" 2>/dev/null)
  [ -z "$project_items" ] && project_items="[]"
  inflight_data=$(jq -r '.[] | select(.status == "In progress" and .state == "OPEN") | "\(.number)\t\(.title)"' <<<"$project_items" 2>/dev/null)

  # Reconcile residue on every load, not only on departure: a closed issue
  # whose card is still In progress (left over from before a watcher
  # restart, say) never appears in flight, so it would never be seen
  # departing and never reach Done.
  while read -r n; do
    [ -z "$n" ] && continue
    project_board_finish "$n"
  done <<<"$(jq -r '.[] | select(.state == "CLOSED" and .status == "In progress") | .number' <<<"$project_items" 2>/dev/null)"
}

project_board_ready() {
  jq -r --argjson open "$project_open_numbers" "$READY_RULES"'
  [ .[]
    | select(.state == "OPEN" and .status == "Todo")
    | select(is_research | not)
    | select(unblocked($open))
    | { number, title, prio: prio }
  ]
  | emit_ready' <<<"$project_items" 2>/dev/null
}

project_item_id_for() { jq -r --argjson n "$1" 'first(.[] | select(.number == $n)) | .item // empty' <<<"$project_items" 2>/dev/null; }
project_status_for() { jq -r --argjson n "$1" 'first(.[] | select(.number == $n)) | .status // empty' <<<"$project_items" 2>/dev/null; }

project_set_status() { # <item id> <option id>
  gh project item-edit --id "$1" --project-id "$CUR_PROJECT_ID" --field-id "$CUR_STATUS_FIELD_ID" --single-select-option-id "$2" >/dev/null 2>&1
}

project_board_claim() {
  local item
  item=$(project_item_id_for "$1")
  [ -n "$item" ] && project_set_status "$item" "$CUR_OPT_IN_PROGRESS"
}

project_board_release() {
  local item
  item=$(project_item_id_for "$1")
  [ -n "$item" ] && project_set_status "$item" "$CUR_OPT_TODO"
}

# Moves a CLOSED issue's card to Done, once. PROJECT_DONE_SYNCED (persisted
# per board as BOARD_<i>_DONE_SYNCED) remembers the numbers already moved so
# the load-time residue sweep and the departure pass cannot double-edit the
# same card in one cycle.
PROJECT_DONE_SYNCED=""
project_board_finish() {
  local num="$1" item status
  if grep -qx "$num" <<<"$PROJECT_DONE_SYNCED"; then return 0; fi
  [ -n "$CUR_OPT_DONE" ] || return 0
  status=$(project_status_for "$num")
  case "$status" in ""|Done) return 0 ;; esac
  item=$(project_item_id_for "$num")
  [ -n "$item" ] || return 0
  if project_set_status "$item" "$CUR_OPT_DONE"; then
    PROJECT_DONE_SYNCED=$(printf '%s\n%s' "$PROJECT_DONE_SYNCED" "$num")
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
# Both backends load inflight_data in the same "<number>\t<title>" shape
# (title_for depends on it too), so slicing numbers out is mode-independent.
board_inflight() {
  [ "$BOARD_FETCH_OK" = 1 ] || return 1
  cut -f1 <<<"$inflight_data" 2>/dev/null | sort -n
}
board_ready() { if [ "$CUR_KIND" = "project" ]; then project_board_ready; else repo_board_ready; fi; }
board_claim() { if [ "$CUR_KIND" = "project" ]; then project_board_claim "$1"; else repo_board_claim "$1"; fi; }
board_release() { if [ "$CUR_KIND" = "project" ]; then project_board_release "$1"; else repo_board_release "$1"; fi; }
board_finish() { if [ "$CUR_KIND" = "project" ]; then project_board_finish "$1"; else repo_board_finish "$1"; fi; }

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
fetch_start_iso() {
  local num="$1" ts
  ts=$(gh api "repos/$CUR_REPO/issues/$num/timeline" \
        --jq '[.[] | select(.event=="labeled" and .label.name=="mgr:in-flight") | .created_at] | last' \
        2>/dev/null)
  if [ -n "$ts" ] && [ "$ts" != "null" ]; then
    printf '%s' "$ts"
  else
    date -u +%FT%TZ
  fi
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
age_comment_for() {
  local num="$1" data url body cid start hours
  data=$(gh issue view "$num" -R "$CUR_REPO" --json comments --jq \
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
create_flight_comment() {
  local num="$1" body="$2" url
  url=$(gh issue comment "$num" -R "$CUR_REPO" --body "$body" 2>/dev/null)
  printf '%s' "${url##*#issuecomment-}"
}

# Rewrites the marker comment in place. Called only on an hour boundary or a
# clock reset, never every cycle, and never posts a second comment.
update_flight_comment() {
  gh api --method PATCH "repos/$CUR_REPO/issues/comments/$1" -f "body=$2" >/dev/null 2>&1
}

# GitHub is the durable record for flight-age state, but it is only READ the
# first time this process sees an issue in flight and only WRITTEN when an
# hour boundary fires; every other cycle is served from this in-memory
# mirror, so steady-state cycles cost zero extra gh calls. One
# "<num>\t<start_iso>\t<start_epoch>\t<hours_reported>\t<comment_id>" row
# per in-flight issue, in a plain newline-delimited string: this script runs
# on bash 3.2, which has no associative arrays. FLIGHT_SEEN_DEPART lists
# issues that left flight while this process watched, so a re-entry is
# distinguishable from first sight after a restart. Both are persisted per
# board (BOARD_<i>_FLIGHT_CACHE / _FLIGHT_SEEN_DEPART) around each
# service_board call.
FLIGHT_CACHE=""
FLIGHT_SEEN_DEPART=""

flight_cache_row() { awk -F'\t' -v n="$1" '$1 == n { print; exit }' <<<"$FLIGHT_CACHE"; }
flight_cache_drop() { FLIGHT_CACHE=$(awk -F'\t' -v n="$1" 'NF && $1 != n' <<<"$FLIGHT_CACHE"); }
flight_cache_put() { # <num> <start_iso> <start_epoch> <hours> <comment_id>
  flight_cache_drop "$1"
  FLIGHT_CACHE=$(printf '%s\n%s\t%s\t%s\t%s\t%s' "$FLIGHT_CACHE" "$1" "$2" "$3" "$4" "$5")
}

# Looks up an in-flight issue's title from this cycle's $inflight_data.
title_for() {
  awk -F'\t' -v n="$1" '$1==n{print $2; exit}' <<<"$inflight_data"
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
# A surviving worktree means the session is still finishing its own teardown,
# and closing the tab under it would kill that mid-step.
#
# Wave-2 seam: tab labels are not yet board-scoped, so with several boards
# whose repos reuse issue numbers this sweep (and the launch-time tab name
# issue-<n>) cannot tell the boards' tabs apart; the closed-state and
# worktree checks below at least run against THIS board's repo and path.
# Board-scoped tab/agent naming lands in wave 2 and closes that hole.
sweep_finished_tabs() {
  local tabs worktrees tab num

  # Emit "<tab_id><TAB><issue number>" straight from jq. Do NOT parse the
  # number out with sed: "\+" is a GNU extension that BSD sed (macOS) treats
  # as a literal plus, so the number came back empty and nothing was ever
  # swept — silently, because an empty number just skips the tab.
  tabs=$(herdr tab list 2>/dev/null \
         | jq -r '.result.tabs[]?
                  | select(.label? // "" | test("^issue-[0-9]+:"))
                  | "\(.tab_id)\t\(.label | capture("^issue-(?<n>[0-9]+):").n)"')
  [ -z "$tabs" ] && return 0

  worktrees=$(git -C "$CUR_PATH" worktree list 2>/dev/null)

  while IFS=$'\t' read -r tab num; do
    [ -z "$tab" ] || [ -z "$num" ] && continue

    # still holding a slot? then it is not finished
    grep -qx "$num" <<<"$inflight" && continue

    [ "$(gh issue view "$num" -R "$CUR_REPO" --json state --jq '.state' 2>/dev/null)" = "CLOSED" ] || continue
    grep -qE "issue-$num([^0-9]|$)" <<<"$worktrees" && continue

    if herdr tab close "$tab" >/dev/null 2>&1; then
      log "issue #$num: closed finished tab $tab"
      report "closed issue #$num's finished tab ($tab): landed, worktree gone, session done."
    fi
  done <<<"$tabs"
}

# Prints "<pr_number><TAB><head_branch>" if an open PR already belongs to this
# issue, else nothing.
#
# Matching is deliberately narrow: the head branch carrying the issue number,
# or a closing keyword in the title/body. A bare "#N" mention is NOT enough —
# PRs routinely name related issues ("related #97/#98/#99 work is not copied"),
# and treating that as ownership hands a session the wrong branch.
existing_pr_for() {
  gh pr list -R "$CUR_REPO" --state open --json number,headRefName,title,body --limit 100 2>/dev/null \
    | jq -r --arg n "$1" '
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
existing_branch_for() {
  git -C "$CUR_PATH" ls-remote --heads origin 2>/dev/null \
    | sed 's#.*refs/heads/##' \
    | grep -E "(^|[^0-9])$1([^0-9]|$)" \
    | head -1
}

# Opens a tab, starts an omp agent, and hands it one specific, already-claimed
# issue. Releases the claim and cleans up the tab if anything fails.
launch_issue() {
  local num="$1" title="$2"
  local name create_json pane tab start_out attempt prompt
  local pr_info pr_num pr_branch adopt branch_only

  name="issue-$num"

  # NOTE: the pane id lives at .result.root_pane.pane_id, NOT .result.tab.pane_id
  # or .result.pane_id — those paths look plausible but don't exist, and jq
  # silently returns empty for them. Getting this wrong makes every launch fail
  # after the tab is already created, leaving a real, visible, agent-less tab
  # with no cleanup. Verified against a live `herdr tab create` response; do not
  # change without re-checking the actual response shape.
  create_json=$(herdr tab create --workspace "$CUR_WS" --no-focus 2>&1) || {
    log "issue #$num: tab create failed: $create_json"
    report "issue #$num could not start: tab create failed. Claim released, issue back in rotation."
    board_release "$num"
    return 1
  }
  pane=$(jq -r '.result.root_pane.pane_id // empty' <<<"$create_json" 2>/dev/null)
  tab=$(jq -r '.result.tab.tab_id // empty' <<<"$create_json" 2>/dev/null)
  if [ -z "$pane" ] || [ -z "$tab" ]; then
    log "issue #$num: tab create returned no pane/tab id, response was: $create_json"
    report "issue #$num could not start: tab create returned no pane id. Claim released, issue back in rotation."
    board_release "$num"
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
    report "issue #$num could not start: agent start failed on pane $pane. Tab closed and claim released, issue back in rotation."
    herdr tab close "$tab" >/dev/null 2>&1
    board_release "$num"
    return 1
  fi

  herdr tab rename "$tab" "issue-$num: $title" >/dev/null 2>&1

  # Hand over any work that already exists for this issue, so the session
  # adopts it instead of starting a second branch and a second PR beside it.
  pr_info=$(existing_pr_for "$num")
  pr_num=$(cut -f1 <<<"$pr_info")
  pr_branch=$(cut -f2 <<<"$pr_info")
  if [ -n "$pr_num" ]; then
    adopt="Work already exists and you are ADOPTING it: open PR #$pr_num on branch $pr_branch. Do not open a new PR and do not start over. Create your worktree from that existing branch, basing it on origin/$pr_branch, then read the issue and that PR (including comments) and the diff against origin/main to establish what is already done, including any uncommitted changes, before you add anything."
  else
    branch_only=$(existing_branch_for "$num")
    if [ -n "$branch_only" ]; then
      adopt="A branch for this issue already exists on origin with no open PR: $branch_only. Inspect it first (git log and diff against origin/main); adopt it and open the draft PR from it if its work is sound, and say so explicitly if you judge it unusable and start fresh instead."
    else
      adopt="No existing branch or PR for this issue: create the worktree and open the draft PR before implementing."
    fi
  fi

  # Mode decides how far a session may take the issue on its own.
  if [ "$CUR_MODE" = "auto" ]; then
    instructions="Autonomous mode is in force. This prompt IS the explicit instruction that next-issue steps 5 to 7 require - do not wait for further approval, and do not ask the operator for routine decisions. In order:
1. If this issue is complex - size:large, cross-cutting, a schema or contract change, or the approach is genuinely unsettled - first run a TIER 2 PLAN per the plan-on-tier skill, then follow it. Skip this for small settled work.
2. Implement, and verify proportionately: only what your change touches, no full-project test suite and no repo-wide formatters.
3. Before landing, run a TIER 2 REVIEW per the review-on-tier skill against your finished diff. This is mandatory on every issue. Fix every real finding, re-review if you changed anything material, and state in your report what it raised and what you did about each item.
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
  if ! board_load; then
    log "board $CUR_NAME: in-flight fetch failed: $(cat "$ERRFILE")"
    return 1
  fi
  inflight=$(board_inflight) || return 1
  count=0
  [ -n "$inflight" ] && count=$(wc -l <<<"$inflight" | tr -d ' ')
  free=$(( CUR_CONC - count ))

  # Anything that left flight since the last cycle: landed, closed, or had its
  # claim dropped by someone else. Worth surfacing — a session landing its own
  # issue is otherwise invisible from here.
  if [ "$first_cycle" -eq 0 ] && [ "$prev_inflight" != "$inflight" ]; then
    while read -r gone; do
      [ -z "$gone" ] && continue
      state=$(gh issue view "$gone" -R "$CUR_REPO" --json state --jq '.state' 2>/dev/null)
      # Reconcile the finished issue's board state: repo mode strips a stale
      # mgr:in-flight, project mode moves the card to Done.
      [ "$state" = "CLOSED" ] && board_finish "$gone"
      # Departure resets the age clock's memory: if the issue re-enters
      # flight, the first-sight path re-reads GitHub - including, in repo
      # mode, the timeline lookup that detects a re-claimed issue's new
      # start. That lookup now runs exactly when it can change the answer.
      flight_cache_drop "$gone"
      grep -qx "$gone" <<<"$FLIGHT_SEEN_DEPART" \
        || FLIGHT_SEEN_DEPART=$(printf '%s\n%s' "$FLIGHT_SEEN_DEPART" "$gone")
      # A card a human dragged out of In progress lands here too: it simply
      # left flight, this report covers it, and the human's move stands.
      report "issue #$gone left flight (issue is now ${state:-unknown}). Slot freed."
    done <<<"$(comm -23 <(printf '%s\n' "$prev_inflight") <(printf '%s\n' "$inflight") 2>/dev/null)"
  fi
  prev_inflight="$inflight"
  first_cycle=0

  # Reconcile finished tabs every cycle, not just on the departure pass: a
  # just-closed issue usually still has its worktree while the session tears
  # down, so it gets swept on a later pass.
  sweep_finished_tabs

  # Long-running-issue notices: once per whole hour an issue has been
  # in-flight, never more than once for the same hour - even across watcher
  # restarts, since the durable clock is each issue's marker comment, not a
  # local file. FLIGHT_CACHE mirrors that record in memory (see its comment):
  # GitHub is read once per flight period, written once per hour boundary,
  # and a steady-state cycle costs zero extra gh calls.
  now_epoch=$(date -u +%s)
  while read -r num; do
    [ -z "$num" ] && continue

    row=$(flight_cache_row "$num")
    if [ -n "$row" ]; then
      # Seen in flight before, and not departed since: serve from memory.
      IFS=$'\t' read -r _ start_iso start_epoch hours_reported comment_id <<<"$row"
      need_write=0
    else
      # First sight of this flight period: read the durable record back.
      comment_id="" start_iso="" hours_reported=0
      marker=$(age_comment_for "$num")
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
        latest_iso=$(fetch_start_iso "$num")
      elif grep -qx "$num" <<<"$FLIGHT_SEEN_DEPART"; then
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
      title=$(title_for "$num")
      log "issue #$num has been in flight for ${elapsed_hours}h: $title"
      report "issue #$num has been in flight for ${elapsed_hours}h: $title."
      hours_reported=$elapsed_hours
      need_write=1
    fi

    if [ "$need_write" -eq 1 ]; then
      if [ -n "$comment_id" ]; then
        update_flight_comment "$comment_id" "$(flight_comment_body "$start_iso" "$hours_reported")"
      else
        comment_id=$(create_flight_comment "$num" "$(flight_comment_body "$start_iso" "$hours_reported")")
      fi
      flight_cache_put "$num" "$start_iso" "$start_epoch" "$hours_reported" "$comment_id"
    elif [ -z "$row" ]; then
      flight_cache_put "$num" "$start_iso" "$start_epoch" "$hours_reported" "$comment_id"
    fi
  done <<<"$inflight"

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

  if [ "$launch" -gt 0 ]; then
    launched=0
    while IFS=$'\t' read -r num title; do
      [ "$launched" -ge "$launch" ] && break
      [ -z "$num" ] && continue
      if ! board_claim "$num"; then
        log "issue #$num: claim failed (raced?), skipping"
        report "issue #$num: could not claim $CLAIM_NOUN (raced with another session?), skipped this cycle."
        continue
      fi
      launch_issue "$num" "$title" || true
      launched=$((launched + 1))
    done <<<"$ready_list"
  fi
  return 0
}

service_board() {
  local i="$1" rc fails skip
  bv "$i" FAILS; fails=$bvv
  # Cheap fixed backoff: after 5 consecutive fetch failures the board is
  # serviced only every 10th cycle — failed calls still burn rate limit and
  # the raw error is already in the log. Any success resets the count.
  if [ "$fails" -ge 5 ]; then
    bv "$i" SKIP; skip=$bvv
    if [ "$skip" -lt 9 ]; then
      bset "$i" SKIP $((skip + 1))
      return 0
    fi
    bset "$i" SKIP 0
  fi
  board_ctx_load "$i"
  board_state_load "$i"
  service_board_cycle
  rc=$?
  board_state_save "$i"
  if [ "$rc" -ne 0 ]; then
    bset "$i" FAILS $((fails + 1))
  elif [ "$fails" -ne 0 ]; then
    bset "$i" FAILS 0
  fi
  # Wave-2 seam: the latched degraded/recovered operator reports fire here,
  # on the FAILS 0 <-> threshold transitions. Not implemented in wave 1.
  return "$rc"
}

b=0
while [ "$b" -lt "$NBOARDS" ]; do
  board_ctx_load "$b"
  log "watcher started: workspace=$CUR_WS concurrency=$CUR_CONC poll=${POLL_SECONDS}s mode=$CUR_MODE"
  if [ "$CUR_KIND" = "project" ]; then
    log "board mode: project $CUR_OWNER/$CUR_NUMBER - the Status single-select is the state machine; labels are not board state"
  fi
  if [ "$CUR_MODE" = "auto" ]; then
    report "started in AUTO mode: concurrency $CUR_CONC, polling every ${POLL_SECONDS}s. Sessions will plan (tier 2 if complex), implement, run a mandatory tier 2 review, then land and finish on their own. mgr:manual-approve still gates the merge: an issue carrying it is left ready for approval, not landed. Will report launches, landings and failures here."
  else
    report "started in supervised mode: concurrency $CUR_CONC, polling every ${POLL_SECONDS}s. Sessions stop after pushing; you instruct ready/land/done in each issue tab. Will report launches and failures here."
  fi
  b=$((b + 1))
done

# The operator's total load, as one visible number: concurrency summed across
# the config, and the steady-state gh request rate (2 fetches per board per
# cycle — in-flight + ready in repo mode, item-list + open-issue list in
# project mode; launches, sweeps and age writes come on top).
TOTAL_CONC=0
CALLS_PER_CYCLE=0
b=0
while [ "$b" -lt "$NBOARDS" ]; do
  bv "$b" CONC
  TOTAL_CONC=$((TOTAL_CONC + bvv))
  CALLS_PER_CYCLE=$((CALLS_PER_CYCLE + 2))
  b=$((b + 1))
done
EST_RPH=$((CALLS_PER_CYCLE * 3600 / POLL_SECONDS))
log "budget: $NBOARDS board(s), total concurrency=$TOTAL_CONC, ~$EST_RPH baseline gh requests/hour at poll=${POLL_SECONDS}s"
if [ "$EST_RPH" -gt 3000 ]; then
  log "WARNING: ~$EST_RPH gh requests/hour is above 3000/h; raise poll_seconds"
fi

while true; do
  b=0
  while [ "$b" -lt "$NBOARDS" ]; do
    service_board "$b" || true
    b=$((b + 1))
  done

  # Backgrounded sleep + wait, so TERM/INT is handled immediately. A plain
  # `sleep "$POLL_SECONDS"` defers the trap until the sleep finishes, which
  # makes a stop take up to a full poll interval and invites a hard kill.
  sleep "$POLL_SECONDS" &
  wait $!
done
