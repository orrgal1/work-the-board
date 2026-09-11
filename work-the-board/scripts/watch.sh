#!/usr/bin/env bash
# work-the-board watcher: keeps <CONCURRENCY> issues in flight by selecting,
# claiming, and handing out ready issues to next-issue sessions.
#
# Usage: watch.sh <workspace_id> <concurrency> [poll_seconds] [report_agent] [supervised|auto] [--project <owner>/<number>]
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
# Every cycle:
#   1. Counts open issues labeled mgr:in-flight (capacity used).
#   2. Selects the READY issues: open, carrying none of mgr:in-flight,
#      mgr:hold, or research, and every "Blocked by: #N" reference
#      closed/absent. Ordered priority:high first, then lowest number.
#   3. For each free slot, takes the next ready issue, CLAIMS it with
#      mgr:in-flight, opens a tab, starts an omp agent, and hands it that
#      specific issue number. Nothing ready means nothing launched.
#   4. Sweeps tabs whose issue is closed and whose worktree is gone.
#   5. Sleeps, then repeats.
#
# The watcher owns selection and claiming so a session is only ever spawned
# when there is real work for it: spawning a session to let it discover
# "nothing ready" burns a throwaway agent and a tab every single cycle.
# A claim is released again if the session fails to come up.
set -uo pipefail

USAGE="usage: watch.sh <workspace_id> <concurrency> [poll_seconds] [report_agent] [supervised|auto] [--project <owner>/<number>]"

# Positionals stay positional; --project is a trailing flag, so every
# existing invocation parses exactly as before.
BOARD_MODE=repo
PROJECT_OWNER=""
PROJECT_NUMBER=""
WORKSPACE=""
CONCURRENCY=""
POLL_SECONDS=30
REPORT_TARGET=""
MODE=supervised
npos=0
while [ $# -gt 0 ]; do
  case "$1" in
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
      BOARD_MODE=project
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

if [ -z "$WORKSPACE" ] || [ -z "$CONCURRENCY" ]; then
  echo "$USAGE" >&2
  exit 2
fi

case "$MODE" in
  supervised|auto) ;;
  *) echo "unknown mode: $MODE" >&2; echo "$USAGE" >&2; exit 2 ;;
esac

# Project mode resolves its ids once, at startup, so a bad board, a missing
# Status option, or a token without the project scope fails HERE with one
# clear message - not later, mid-cycle, once per issue.
PROJECT_ID=""
STATUS_FIELD_ID=""
REPO_NWO=""
OPT_TODO=""
OPT_IN_PROGRESS=""
OPT_DONE=""
if [ "$BOARD_MODE" = "project" ]; then
  fields_json=$(gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json 2>&1) || {
    if grep -q "missing required scopes" <<<"$fields_json"; then
      echo "watch.sh: gh token lacks the project scope; run: gh auth refresh -s project" >&2
    else
      echo "watch.sh: cannot read fields of project $PROJECT_OWNER/$PROJECT_NUMBER: $fields_json" >&2
    fi
    exit 2
  }
  STATUS_FIELD_ID=$(jq -r '[.fields[]? | select(.name == "Status" and has("options"))][0].id // empty' <<<"$fields_json" 2>/dev/null)
  if [ -z "$STATUS_FIELD_ID" ]; then
    echo "watch.sh: project $PROJECT_OWNER/$PROJECT_NUMBER has no single-select Status field" >&2
    exit 2
  fi
  status_option_id() {
    jq -r --arg n "$1" '[.fields[]? | select(.name == "Status" and has("options"))][0].options[]? | select(.name == $n) | .id' <<<"$fields_json" 2>/dev/null
  }
  OPT_TODO=$(status_option_id "Todo")
  OPT_IN_PROGRESS=$(status_option_id "In progress")
  OPT_DONE=$(status_option_id "Done")
  if [ -z "$OPT_TODO" ]; then
    echo "watch.sh: Status field of project $PROJECT_OWNER/$PROJECT_NUMBER has no Todo option" >&2
    exit 2
  fi
  if [ -z "$OPT_IN_PROGRESS" ]; then
    echo "watch.sh: Status field of project $PROJECT_OWNER/$PROJECT_NUMBER has no 'In progress' option" >&2
    exit 2
  fi
  PROJECT_ID=$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json 2>/dev/null | jq -r '.id // empty' 2>/dev/null)
  if [ -z "$PROJECT_ID" ]; then
    echo "watch.sh: cannot resolve the node id of project $PROJECT_OWNER/$PROJECT_NUMBER" >&2
    exit 2
  fi
  # item-list reports each item's repo but not the issue's open/closed state,
  # so board_load cross-references this repo's open issues; items from other
  # repos on the board are not this watcher instance's to launch.
  REPO_NWO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
  if [ -z "$REPO_NWO" ]; then
    echo "watch.sh: cannot resolve this checkout's repository (gh repo view failed)" >&2
    exit 2
  fi
fi

# Mode-dependent wording for handout prompts and reports; the repo-mode
# strings are the original text, byte for byte.
if [ "$BOARD_MODE" = "project" ]; then
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

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

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
# Board backends. The main loop only calls board_load / board_inflight /
# board_ready / board_claim / board_release / board_finish; BOARD_MODE picks
# the implementation. Repo mode is the original mgr:* label state machine,
# unchanged. Project mode reads and writes the board's Status single-select
# instead, and never reads or writes labels for board state.
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
  inflight_data=$(gh issue list --state open --label mgr:in-flight --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null)
}

# Prints ready issues, one per line, as "<number><TAB><title>".
repo_board_ready() {
  local data
  data=$(gh issue list --state open --json number,title,labels,body --limit 200 2>/dev/null) || return 0
  [ -z "$data" ] && return 0
  jq -r "$READY_FILTER" <<<"$data" 2>/dev/null
}

repo_board_claim() { gh issue edit "$1" --add-label mgr:in-flight >/dev/null 2>&1; }
repo_board_release() { gh issue edit "$1" --remove-label mgr:in-flight >/dev/null 2>&1; }

# A closed issue still carrying mgr:in-flight is pure residue: the label no
# longer gates anything (capacity only counts open issues) but it is exactly
# what accumulates into a board nobody can read. Sessions sometimes close the
# issue and exit before dropping it. No judgment needed once the issue is
# closed, so strip it.
repo_board_finish() {
  if gh issue view "$1" --json labels --jq '[.labels[].name] | index("mgr:in-flight") // empty' 2>/dev/null | grep -q .; then
    gh issue edit "$1" --remove-label mgr:in-flight >/dev/null 2>&1 \
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
# numbers. Draft items, PRs, and issues of other repos are skipped.
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
  raw=$(gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 200 2>/dev/null) || raw=""
  project_open_numbers=$(gh issue list --state open --json number --limit 200 --jq '[.[].number]' 2>/dev/null)
  [ -z "$project_open_numbers" ] && project_open_numbers="[]"
  project_items=$(jq -c --arg repo "$REPO_NWO" --argjson open "$project_open_numbers" "$PROJECT_NORMALIZE" <<<"$raw" 2>/dev/null)
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
  gh project item-edit --id "$1" --project-id "$PROJECT_ID" --field-id "$STATUS_FIELD_ID" --single-select-option-id "$2" >/dev/null 2>&1
}

project_board_claim() {
  local item
  item=$(project_item_id_for "$1")
  [ -n "$item" ] && project_set_status "$item" "$OPT_IN_PROGRESS"
}

project_board_release() {
  local item
  item=$(project_item_id_for "$1")
  [ -n "$item" ] && project_set_status "$item" "$OPT_TODO"
}

# Moves a CLOSED issue's card to Done, once. PROJECT_DONE_SYNCED remembers
# the numbers already moved so the load-time residue sweep and the departure
# pass cannot double-edit the same card in one cycle.
PROJECT_DONE_SYNCED=""
project_board_finish() {
  local num="$1" item status
  if grep -qx "$num" <<<"$PROJECT_DONE_SYNCED"; then return 0; fi
  [ -n "$OPT_DONE" ] || return 0
  status=$(project_status_for "$num")
  case "$status" in ""|Done) return 0 ;; esac
  item=$(project_item_id_for "$num")
  [ -n "$item" ] || return 0
  if project_set_status "$item" "$OPT_DONE"; then
    PROJECT_DONE_SYNCED=$(printf '%s\n%s' "$PROJECT_DONE_SYNCED" "$num")
    log "issue #$num: closed issue's card moved to Done"
  fi
}

# --- dispatch ---------------------------------------------------------------

board_load() { if [ "$BOARD_MODE" = "project" ]; then project_board_load; else repo_board_load; fi; }
# Both backends load inflight_data in the same "<number>\t<title>" shape
# (title_for depends on it too), so slicing numbers out is mode-independent.
board_inflight() { cut -f1 <<<"$inflight_data" 2>/dev/null | sort -n; }
board_ready() { if [ "$BOARD_MODE" = "project" ]; then project_board_ready; else repo_board_ready; fi; }
board_claim() { if [ "$BOARD_MODE" = "project" ]; then project_board_claim "$1"; else repo_board_claim "$1"; fi; }
board_release() { if [ "$BOARD_MODE" = "project" ]; then project_board_release "$1"; else repo_board_release "$1"; fi; }
board_finish() { if [ "$BOARD_MODE" = "project" ]; then project_board_finish "$1"; else repo_board_finish "$1"; fi; }

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
  ts=$(gh api "repos/{owner}/{repo}/issues/$num/timeline" \
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
  data=$(gh issue view "$num" --json comments --jq \
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
  url=$(gh issue comment "$num" --body "$body" 2>/dev/null)
  printf '%s' "${url##*#issuecomment-}"
}

# Rewrites the marker comment in place. Called only on an hour boundary or a
# clock reset, never every cycle, and never posts a second comment.
update_flight_comment() {
  gh api --method PATCH "repos/{owner}/{repo}/issues/comments/$1" -f "body=$2" >/dev/null 2>&1
}

# GitHub is the durable record for flight-age state, but it is only READ the
# first time this process sees an issue in flight and only WRITTEN when an
# hour boundary fires; every other cycle is served from this in-memory
# mirror, so steady-state cycles cost zero extra gh calls. One
# "<num>\t<start_iso>\t<start_epoch>\t<hours_reported>\t<comment_id>" row
# per in-flight issue, in a plain newline-delimited string: this script runs
# on bash 3.2, which has no associative arrays. FLIGHT_SEEN_DEPART lists
# issues that left flight while this process watched, so a re-entry is
# distinguishable from first sight after a restart.
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

  worktrees=$(git -C "$PWD" worktree list 2>/dev/null)

  while IFS=$'\t' read -r tab num; do
    [ -z "$tab" ] || [ -z "$num" ] && continue

    # still holding a slot? then it is not finished
    grep -qx "$num" <<<"$inflight" && continue

    [ "$(gh issue view "$num" --json state --jq '.state' 2>/dev/null)" = "CLOSED" ] || continue
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
  gh pr list --state open --json number,headRefName,title,body --limit 100 2>/dev/null \
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
  git ls-remote --heads origin 2>/dev/null \
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
  create_json=$(herdr tab create --workspace "$WORKSPACE" --no-focus 2>&1) || {
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
  if [ "$MODE" = "auto" ]; then
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

log "watcher started: workspace=$WORKSPACE concurrency=$CONCURRENCY poll=${POLL_SECONDS}s mode=$MODE"
if [ "$BOARD_MODE" = "project" ]; then
  log "board mode: project $PROJECT_OWNER/$PROJECT_NUMBER - the Status single-select is the state machine; labels are not board state"
fi
if [ "$MODE" = "auto" ]; then
  report "started in AUTO mode: concurrency $CONCURRENCY, polling every ${POLL_SECONDS}s. Sessions will plan (tier 2 if complex), implement, run a mandatory tier 2 review, then land and finish on their own. mgr:manual-approve still gates the merge: an issue carrying it is left ready for approval, not landed. Will report launches, landings and failures here."
else
  report "started in supervised mode: concurrency $CONCURRENCY, polling every ${POLL_SECONDS}s. Sessions stop after pushing; you instruct ready/land/done in each issue tab. Will report launches and failures here."
fi

prev_inflight=""
first_cycle=1

while true; do
  board_load
  inflight=$(board_inflight)
  count=0
  [ -n "$inflight" ] && count=$(wc -l <<<"$inflight" | tr -d ' ')
  free=$(( CONCURRENCY - count ))

  # Anything that left flight since the last cycle: landed, closed, or had its
  # claim dropped by someone else. Worth surfacing — a session landing its own
  # issue is otherwise invisible from here.
  if [ "$first_cycle" -eq 0 ] && [ "$prev_inflight" != "$inflight" ]; then
    while read -r gone; do
      [ -z "$gone" ] && continue
      state=$(gh issue view "$gone" --json state --jq '.state' 2>/dev/null)
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
      if [ "$BOARD_MODE" = "repo" ]; then
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

  ready_list=$(board_ready)
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

  # Backgrounded sleep + wait, so TERM/INT is handled immediately. A plain
  # `sleep "$POLL_SECONDS"` defers the trap until the sleep finishes, which
  # makes a stop take up to a full poll interval and invites a hard kill.
  sleep "$POLL_SECONDS" &
  wait $!
done
