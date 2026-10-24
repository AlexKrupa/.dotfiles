#!/usr/bin/env bash
# Usage: watch.sh [--repo PATH] [--interval SECONDS] [--once] [--fresh] [--review] [--mr IID]...
#        watch.sh unsubscribe [--repo PATH] [--review] [--mr IID]...
#        watch.sh status
#        watch.sh kind KIND [--workspace ID]
#        watch.sh route --iid IID --action bump|review|none [--repo PATH]
#        watch.sh report [--repo PATH] [--review] [--mr IID]... <JSON
# The client of the watch daemon watchd.sh, for the background task of a session. It starts the
# daemon if no daemon runs, writes its subscription, waits for the events of the subscription,
# and prints one JSON line for each event. The flags, the modes, and the events are as in the
# header of watch-gitlab.sh.
# The subscription stays live after the client exits: the events of the time with no client wait
# for the next client. It ends when the session exits, after unsubscribe, after an error (exit 1),
# when all its MRs are merged or closed, and after 30 minutes with no client. The next client of
# the session still gets the events and the error of an ended subscription.
# unsubscribe: end the subscription of the repo and mode of this session.
# status: the daemon PID, the last poll of each repo, and one TSV line for each subscription: key,
# mode, MRs, live or dead session, inbox line count.
# kind: set the kind of work of the herdr workspace (mine, review, bump, debug, or hub) for the
# sidebar, in $WATCHD_DIR/workspaces/<ID>.json. The workspace is ID, else $HERDR_WORKSPACE_ID.
# With no workspace it does nothing. With no live subscription in the workspace, it also clears
# the stage. A subscription in a workspace with no kind sets the kind of its mode: mine for a
# stack, review, or hub. The herdr plugin `watch` writes the sidebar values from these files.
# route: add the router result of an opened event of the hub to the event log, with the hub key
# of the repo. The herdr plugin `watch` uses it for the notification of the new MR.
# report: print the Markdown report of the last delivery of the subscription (the lines that the
# client printed last) and of its open items. The flags of the watch command select the
# subscription. stdin is a JSON object, all fields optional, empty is {}:
#   {"cells": {"<row>": "<text>"}, "agent": ["<row>"], "close": ["<row>"],
#    "add": [{"section": "needs"|"agent"|"info", "iid": <n>|null, "what", "result"}]}
#   cells: the Proposal or result text of a row. An open item keeps it for the next reports.
#   agent: rows that go to the Agent section. An open item in it closes.
#   close: open items that close, also items of the model. A row with no open item is not in
#   this report.
#   add: a needs row opens an item of the model, with a new number. An agent or info row is
#   only in this report.
# Sections: Needs you (all open items), Agent, Info (the other events of the delivery). The
# layout is in watch-report.jq: one table in hub mode, else one table for each MR.
# With new scripts, a waiting client starts itself again with the same PID and flags.
# Exit codes: 0 events, 1 error, 3 a new client or session replaced this one
set -euo pipefail

die() { echo "watch: $1" >&2; exit 1; }
# shellcheck source=watch-state.sh
source "$HOME/.config/agents/bin/watch/watch-state.sh"

if [[ ${1:-} == kind ]]; then
  [[ $# -ge 2 ]] || die "kind needs a kind"
  kind=$2
  workspace=${HERDR_WORKSPACE_ID:-}
  shift 2
  while (($#)); do
    case "$1" in
      --workspace) [[ $# -ge 2 ]] || die "--workspace needs an ID"; workspace=$2; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  case $kind in
    mine | review | bump | debug | hub) ;;
    *) die "unknown kind: $kind" ;;
  esac
  [[ -n $workspace ]] || exit 0
  mkdir -p "$WATCHD_DIR"
  # With no live watch in the workspace, a new task starts: the end stage of an earlier watch
  # does not apply to it.
  for session in $(jq -r --arg w "$workspace" 'select(.herdr_workspace == $w) | .session_pid' \
      "$WATCHD_DIR"/subs/*.json 2>/dev/null); do
    if watch_alive "$session"; then
      watch_workspace_update "$workspace" --arg kind "$kind" '.kind = $kind'
      exit 0
    fi
  done
  watch_workspace_update "$workspace" --arg kind "$kind" '.kind = $kind | .stage = null'
  exit 0
fi

if [[ ${1:-} == route ]]; then
  shift
  repo=$PWD
  iid=''
  action=''
  while (($#)); do
    case "$1" in
      --repo) [[ $# -ge 2 ]] || die "--repo needs a path"; repo=$2; shift 2 ;;
      --iid) [[ $# -ge 2 && ${2#!} =~ ^[0-9]+$ ]] || die "--iid needs an MR number"
        iid=${2#!}; shift 2 ;;
      --action) [[ $# -ge 2 ]] || die "--action needs an action"; action=$2; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [[ -n $iid ]] || die "route needs --iid"
  case $action in
    bump | review | none) ;;
    *) die "unknown action: $action" ;;
  esac
  cd "$repo" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $repo"
  key=$(watch_key "$(git rev-parse --show-toplevel)" 0)
  mkdir -p "$WATCHD_DIR"
  watch_event_log "$(jq -nc --argjson now "$EPOCHSECONDS" --arg key "$key" --argjson iid "$iid" \
    --arg action "$action" \
    '{time: $now, type: "route", slug: $key, key: $key, iid: $iid, action: $action}')"
  exit 0
fi

command=wait
case ${1:-} in
  unsubscribe | status | report) command=$1; shift ;;
esac
# --fresh applies once: the client starts again with new scripts and keeps the saved state.
restart_args=()
for arg in "$@"; do [[ $arg == --fresh ]] || restart_args+=("$arg"); done
repo=$PWD
interval=120
once=0
mrs=()
review=0
fresh=0
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo needs a path"; repo=$2; shift 2 ;;
    --interval) [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || die "--interval needs seconds"
      interval=$2; shift 2 ;;
    --once) once=1; shift ;;
    --mr) [[ $# -ge 2 && ${2#!} =~ ^[0-9]+$ ]] || die "--mr needs an MR number"
      mrs+=("${2#!}"); shift 2 ;;
    --review) review=1; shift ;;
    --fresh) fresh=1; shift ;;
    *) die "unexpected argument: $1" ;;
  esac
done
if ((review)) && ((${#mrs[@]} != 1)); then die "--review needs exactly one --mr"; fi
command -v jq >/dev/null || die "jq is not installed"
mkdir -p "$WATCHD_DIR"/{subs,inbox,poke,rounds,repos,items}
shopt -s nullglob

daemon_alive() {
  local pid
  pid=$(cat "$WATCHD_DIR/daemon.pid" 2>/dev/null) || return 1
  [[ $(ps -o command= -p "$pid" 2>/dev/null) == *watchd.sh* ]]
}

if [[ $command == status ]]; then
  if daemon_alive; then echo "daemon $(cat "$WATCHD_DIR/daemon.pid")"; else echo "no daemon"; fi
  for file in "$WATCHD_DIR"/repos/*.pid; do
    echo "$(basename "$file" .pid) last poll $(stat -f %Sm -t %H:%M:%S "$file")"
  done
  for file in "$WATCHD_DIR"/subs/*.json; do
    key=$(basename "$file" .json)
    # The daemon can remove the record during the loop.
    record=$(cat "$file" 2>/dev/null) || continue
    lines=0
    [[ -f $WATCHD_DIR/inbox/$key.jsonl ]] && lines=$(wc -l <"$WATCHD_DIR/inbox/$key.jsonl")
    live=dead
    watch_alive "$(jq -r .session_pid <<<"$record")" && live=live
    jq -r --arg live "$live" --arg lines "${lines// /}" '[.key, .mode,
        ([.mrs[] | tostring] | join(",") | if . == "" then "-" else . end), $live, $lines]
      | @tsv' <<<"$record"
  done
  exit 0
fi

cd "$repo" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $repo"
top=$(git rev-parse --show-toplevel)
slug=$("$WATCH_BIN/../repo-slug.sh")
key=$(watch_key "$top" "$review" "${mrs[@]}")
sub=$WATCHD_DIR/subs/$key.json
inbox=$WATCHD_DIR/inbox/$key.jsonl
error=$WATCHD_DIR/inbox/$key.error
owner=$WATCHD_DIR/inbox/$key.owner

session=$(watch_session_pid)
if ((review)); then mode=review; elif ((${#mrs[@]})); then mode=stack; else mode=hub; fi
# in: $input (the JSON of the model), $items (the items file), $delivery (the last delivery),
# $engine (the engine state). out: {items, known, rows, links} for watch-report.jq.
REPORT_PROGRAM='
  ($input.cells // {}) as $cells
  | ($input.agent // [] | map(tostring)) as $agent
  | ($input.close // [] | map(tostring)) as $close
  | ($items[0] // {next: 1, items: []}) as $start
  # One event for each row: a comment before its unaddressed line.
  | ($delivery | group_by(.row) | map(sort_by(.kind == "unaddressed") | .[0]) | sort_by(.row))
    as $events
  # Each round with events repeats the unaddressed line of each open thread.
  | [$delivery[] | select(.kind != "unaddressed") | .row | tostring] as $delivered
  | (reduce ([$delivery[], $start.items[]][] | select(.iid != null)) as $x ({};
      .[$x.iid | tostring] //= {title: $x.title, url: ($x.url // "" | sub("#.*$"; ""))})
    # The engine state has the titles of the MRs with no event.
    | reduce ($engine[0].mrs // {} | to_entries[]) as $e (.;
      .[$e.key] //= {title: $e.value.title, url: null})) as $mrs
  | ($start | .items |= map(.result = ($cells[.n | tostring] // .result))) as $updated
  | [$updated.items[] | select(.n | tostring | IN($agent[]))] as $agent_items
  | (reduce ($input.add // [])[] as $add
      ({state: ($updated | .items |= map(select(.n | tostring | IN($agent[], $close[]) | not))),
        rows: []};
      .state.next as $n | .state.next += 1
      | ($mrs[$add.iid | tostring] // {}) as $mr
      | if $add.section == "needs" then
          .state.items += [{n: $n, item: "model:\($n)", owner: "model", iid: $add.iid,
            title: $mr.title, url: $mr.url, what: $add.what, result: ($add.result // ""),
            since: $now, event: null, new: true}]
        else
          .rows += [{n: $n, section: (if $add.section == "agent" then "Agent" else "Info" end),
            iid: $add.iid, title: $mr.title, url: $mr.url, event: null, what: $add.what,
            result: ($add.result // ""), since: null}]
        end)) as $added
  | [$added.state.items[].n | tostring] as $open
  | def item_row($section):
      {n, section: $section, iid, title: (.title // .event.branch), url, event, what,
       result: (.result // ""),
       since: (if .new or (.n | tostring | IN($delivered[])) then null else .since end)};
    def event_row($section):
      {n: .row, section: $section, iid, title: (.title // .branch), url, event: ., what: null,
       result: ($cells[.row | tostring] // ""), since: null};
  ([$added.state.items | sort_by(.n)[] | item_row("Needs you")]
    + [$agent[] as $id
      | ([$agent_items[] | select(.n | tostring == $id) | item_row("Agent")]
        + [$events[] | select(.row | tostring == $id) | event_row("Agent")])[0] // empty]
    + [$added.rows[] | select(.section == "Agent")]
    + [$events[] | select(.row | tostring | IN($open[], $agent[], $close[]) | not)
      | event_row("Info")]
    + [$added.rows[] | select(.section == "Info")]) as $rows
  | {items: ($added.state | del(.items[].new)),
     known: $mrs,
     rows: $rows,
     links: ([$rows[] | select((.url // "") != "")
       | {key: (if .iid then "!\(.iid)" else .title end), title, iid,
          url: (.url | sub("#.*$"; ""))}]
       | reduce .[] as $link ([]; if any(.[]; .key == $link.key) then . else . + [$link] end)
       | map(del(.key)))}'

if [[ $command == report ]]; then
  input=$(cat)
  [[ -n ${input//[[:space:]]/} ]] || input='{}'
  jq -e 'type == "object"' <<<"$input" >/dev/null 2>&1 || die "report needs a JSON object on stdin"
  items=$WATCHD_DIR/items/$key.json
  watch_lock "$items.lock" || exit 1
  if ! result=$(jq -n --argjson input "$input" --slurpfile items <(cat "$items" 2>/dev/null) \
    --slurpfile delivery <(cat "$WATCHD_DIR/inbox/$key.last.jsonl" 2>/dev/null) \
    --slurpfile engine <(cat "$WATCH_ENGINE_DIR/$key.json" 2>/dev/null) \
    --argjson now "$EPOCHSECONDS" "$REPORT_PROGRAM"); then
    watch_unlock "$items.lock"
    die "report: jq could not read the input or the state"
  fi
  jq '.items' <<<"$result" >"$items.tmp" && mv "$items.tmp" "$items"
  watch_unlock "$items.lock"
  jq --arg mode "$mode" --arg time "$(date +%H:%M)" \
    --argjson mrs "$(printf '%s\n' "${mrs[@]}" | jq -sc .)" \
    '{mode: $mode, time: $time, mrs: $mrs, known, rows, links}' <<<"$result" \
    | jq -r -f "$WATCH_BIN/watch-report.jq"
  exit 0
fi

if [[ $command == unsubscribe ]]; then
  watch_lock "$sub.lock" || exit 1
  # For example, an unsubscribe with no flags in a stack session has the key of the hub.
  record_session=$(jq -r '.session_pid // empty' "$sub" 2>/dev/null || true)
  if [[ -n $record_session && $record_session != "$session" ]] && watch_alive "$record_session"
  then
    watch_unlock "$sub.lock"
    die "the subscription $key is of session $record_session"
  fi
  workspace=$(jq -r '.herdr_workspace // empty' "$sub" 2>/dev/null || true)
  # The open items of a review go back to the hub. The hub keeps its items.
  case $mode in
    review) watch_items_move "$key" "$slug" ;;
    stack) rm -f "$WATCHD_DIR/items/$key.json" ;;
  esac
  rm -f "$sub" "$inbox" "$error" "$owner" "$WATCHD_DIR/poke/$key" "$WATCHD_DIR/rounds/$key" \
    "$WATCHD_DIR/rounds/$key.poked" "$WATCHD_DIR/inbox/$key.last.jsonl"
  if [[ -n $workspace ]]; then watch_workspace_update "$workspace" '.stage = "stopped"'; fi
  watch_unlock "$sub.lock"
  watch_log "$slug" "$key" "unsubscribed"
  exit 0
fi

# The lock makes sure that two clients do not start two daemons. Claude Code stops a background task
# with its process group, so the daemon gets a new session (setsid), and the subshell makes launchd
# its parent.
start_daemon() {
  watch_lock "$WATCHD_DIR/start.lock" || exit 1
  if ! daemon_alive; then
    # A restart file of a daemon that died makes the new daemon exit at once.
    rm -f "$WATCHD_DIR/daemon.pid" "$WATCHD_DIR/restart"
    (/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec {$ARGV[0]} @ARGV' "$WATCH_BIN/watchd.sh" \
      </dev/null \
      >>"$WATCHD_DIR/watchd.log" 2>&1 &)
    for _ in $(seq 50); do daemon_alive && break; sleep 0.2; done
  fi
  watch_unlock "$WATCHD_DIR/start.lock"
  daemon_alive || die "the daemon did not start, see $WATCHD_DIR/watchd.log"
}

# The parent of this script can be a wrapper shell that stays alive after the agent is killed,
# so the check covers all ancestors.
ancestors=()
p=$PPID
while ((p > 1)); do ancestors+=("$p"); p=$(ps -o ppid= -p "$p" | tr -d ' '); done
parent_gone() {
  local p
  for p in "${ancestors[@]}"; do watch_alive "$p" || return 0; done
  return 1
}
exit_if_orphaned() {
  parent_gone && die "the parent process is gone"
  [[ -d $top ]] || die "the worktree is gone: $top"
}

# The daemon writes the text of the poke to this file after the check of the key.
poked=$WATCHD_DIR/rounds/$key.poked
poke_token=$$-$EPOCHSECONDS
((fresh)) && rm -f "$WATCH_ENGINE_DIR/$key.json"
# New scripts, for example after a chezmoi update: the daemon starts again after its current
# round. An older daemon exits, and this client starts the new one. The state is on disk, so no
# event is lost.
hash=$(watch_scripts_hash)
seen_hash=$hash
if daemon_alive && [[ $(cat "$WATCHD_DIR/daemon.hash" 2>/dev/null) != "$hash" ]]; then
  watch_log "" "" "new scripts: restart"
  touch "$WATCHD_DIR/restart"
  for _ in $(seq 300); do
    daemon_alive && [[ $(cat "$WATCHD_DIR/daemon.hash" 2>/dev/null) != "$hash" ]] || break
    sleep 0.2
  done
fi
start_daemon

replaced() { echo "watch: a new client or session replaced this one" >&2; exit 3; }
# Usage: default_kind KIND. The role skills set their kind before they watch. A watch that started
# before its skill set a kind gets the kind of its mode.
default_kind() {
  watch_workspace_update "$HERDR_WORKSPACE_ID" --arg kind "$1" '.kind //= $kind' || true
}
# Writes the record. The newest session owns the key: it adds the old live session to
# replaced_sessions.
subscribe() {
  local old_session replaced_session=null
  old_session=$(jq -r '.session_pid // empty' <<<"$old")
  if [[ -n $old_session && $old_session != "$session" ]] && watch_alive "$old_session"; then
    replaced_session=$old_session
  fi
  jq -n --arg key "$key" --arg slug "$slug" --arg repo "$top" --arg mode "$mode" \
    --argjson interval "$interval" --argjson session "$session" --argjson client $$ \
    --argjson now "$EPOCHSECONDS" --argjson old "$old" --argjson replaced "$replaced_session" \
    --arg workspace "${HERDR_WORKSPACE_ID:-}" '
    ($ARGS.positional | map(tonumber)) as $mrs | ($old.ended_mrs // []) as $ended
    | {key: $key, slug: $slug, repo: $repo, mode: $mode, mrs: $mrs, interval: $interval,
       session_pid: $session, client_pid: $client, client_at: $now,
       replaced_sessions: ($old.replaced_sessions // [] | . + [$replaced // empty] | unique),
       ended_mrs: ($ended - ($ended - $mrs))}
      + if $workspace == "" then {} else {herdr_workspace: $workspace} end' \
    --args "${mrs[@]}" >"$sub.tmp"
  mv "$sub.tmp" "$sub"
  rm -f "$owner"
  if [[ -n ${HERDR_WORKSPACE_ID:-} ]]; then
    case $mode in
      stack) default_kind mine ;;
      review) default_kind review ;;
      hub) default_kind hub ;;
    esac
  fi
  # A new subscription gets its first check now, as with --once.
  if [[ $old == null ]] || ((once)); then echo "$poke_token" >"$WATCHD_DIR/poke/$key"; fi
  watch_log "$slug" "$key" "subscribed: $mode ${mrs[*]+${mrs[*]}}"
}

watch_lock "$sub.lock" || exit 1
old=$(cat "$sub" 2>/dev/null || echo null)
if jq -e --argjson session "$session" '.replaced_sessions // [] | index($session)' <<<"$old" \
  >/dev/null; then
  watch_unlock "$sub.lock"
  replaced
fi
# The results of an ended subscription are only for the next client of its session.
if [[ $old == null && $(cat "$owner" 2>/dev/null) != "$session" ]]; then
  rm -f "$inbox" "$error" "$owner"
fi
# No record, but an error or events: the subscription ended with no client. This client gives the
# result and does not subscribe again.
ended_with_result() { [[ $old == null ]] && [[ -f $error || -s $inbox ]]; }
ended_with_result || subscribe
watch_unlock "$sub.lock"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
while :; do
  # The daemon writes the error or the last events before it removes the record, under the same
  # lock.
  watch_lock "$sub.lock" || exit 1
  ended=0
  [[ -f $sub ]] || ended=1
  if [[ -f $error ]]; then
    cat "$error" >&2
    rm -f "$error" "$owner"
    watch_unlock "$sub.lock"
    exit 1
  fi
  if ((!ended)) && [[ $(jq -r '"\(.client_pid) \(.session_pid)"' "$sub") != "$$ $session" ]]; then
    watch_unlock "$sub.lock"
    replaced
  fi
  watch_unlock "$sub.lock"
  # With --once, the client takes the inbox only after the check of its own poke. The daemon writes
  # the token after it routes the events of that check, so a check that started before the poke
  # does not count.
  own_round=0
  if [[ $(cat "$poked" 2>/dev/null) == "$poke_token" ]]; then own_round=1; fi
  if ((!once || ended || own_round)); then
    watch_lock "$inbox.lock" || exit 1
    [[ -s $inbox ]] && mv "$inbox" "$tmp"
    watch_unlock "$inbox.lock"
    if [[ -s $tmp ]] || ((once && own_round)); then
      if ((ended)); then rm -f "$owner"; fi
      # The delivery of the next report command.
      cp "$tmp" "$WATCHD_DIR/inbox/$key.last.jsonl"
      cat "$tmp"
      exit 0
    fi
  fi
  ((ended)) && die "the subscription ended"
  daemon_alive || start_daemon
  watch_sub_update "$key" --argjson now "$EPOCHSECONDS" '.client_at = $now' || true
  exit_if_orphaned
  # The same PID keeps the subscription. A hash that stays for one tick is the full update.
  new_hash=$(watch_scripts_hash)
  if [[ $new_hash != "$hash" && $new_hash == "$seen_hash" ]]; then
    watch_log "$slug" "$key" "new scripts: client restart"
    rm -f "$tmp"
    exec "$WATCH_BIN/watch.sh" "${restart_args[@]}"
  fi
  seen_hash=$new_hash
  sleep "${WATCH_CLIENT_TICK:-3}"
done
