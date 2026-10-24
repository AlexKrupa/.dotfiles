#!/usr/bin/env bash
# Usage: watchd.sh
# The watch daemon: one process for each machine. watch.sh starts it when no daemon runs.
# It runs one poll loop for each repo with a live subscription. A subscription is live while its
# session process runs. Each round runs the check engine (watch-gitlab.sh) for each live
# subscription of the repo, and appends the events to the inbox of the subscription. The hub check
# skips the MRs of the live review subscriptions. The fetched MRs go to a cache of the round, so
# two subscriptions of one MR get one fetch. The round interval is the smallest --interval of the
# subscriptions of the repo.
# A network error does not count: the loop waits for the network, with no limit. A permanent
# error, or 5 other errors in a row, end the subscription, and its client gets the error text.
# A subscription also ends when all its MRs are merged or closed, and after 30 minutes with no
# client. The next client of its session still gets the events and the error that wait.
# A poke file (watch.sh --once, or a new subscription) starts a round of the repo now. After the
# check of the key, rounds/<key>.poked has the text of the poke.
# With no subscription for 10 minutes, the daemon exits. With new scripts or a restart file, it
# starts itself again with the same PID, after the current round of each repo.
# State and log: $WATCHD_DIR, see watch-state.sh. The log has one line for each event of the
# daemon: time, repo slug, subscription key, message.
# The event log events.jsonl has one JSON line for each routed event, before it goes to the inbox:
#   {"time", "round": "<key>-<time>", "type": "event", "slug", "key", "mode", "event", "sound"}
# sound is request for todo, note, default-failed, comment, conflict, and a failed pipeline, else
# none. A subscription that ends with an error adds {"time", "type": "stopped", "slug", "key",
# "mode", "title", "error"}: title is the title of its first MR, null in hub mode, and error is
# the first line of the error text. watch.sh route adds the router result of the hub model.
# workspaces/<id>.json has the kind and the end stage (done or stopped) of a herdr workspace.
# items/<key>.json has the open items of a subscription, see watch_items_move. Each routed event
# gets row: the number of its open item (the item key of the engine), or a new number. After each
# check, the daemon closes the daemon items whose cause GitLab does not show (the engine present
# list). A live review key takes the open hub items of its MR, and gives its open items back to
# the hub when it ends.
# The daemon makes no herdr call. At its start and once an hour, it removes the event log lines
# and the engine states with no record that are older than 7 days.
# Test seams: WATCHD_TICK (main loop seconds), WATCHD_IDLE_SECONDS, WATCHD_CLIENT_SECONDS,
# WATCHD_ENGINE.
# No `set -e`: an error in one round must not stop the watches of all sessions.
set -uo pipefail

# shellcheck source=watch-lib.sh
source "$HOME/.config/agents/bin/watch-lib.sh"
# shellcheck source=watch-state.sh
source "$HOME/.config/agents/bin/watch-state.sh"

tick=${WATCHD_TICK:-5}
idle_seconds=${WATCHD_IDLE_SECONDS:-600}
client_seconds=${WATCHD_CLIENT_SECONDS:-1800}
engine=${WATCHD_ENGINE:-$WATCH_BIN/watch-gitlab.sh}
shopt -s nullglob
cd / || exit 1
mkdir -p "$WATCHD_DIR"/{subs,inbox,poke,rounds,repos,items}
sleeper=''
# A short nap step, so that a poke or a restart gets an answer in seconds.
WATCH_NAP_STEP=2

# Usage: field KEY FILTER. Prints a field of the record of KEY.
field() {
  jq -r "$2" "$WATCHD_DIR/subs/$1.json" 2>/dev/null
}

is_daemon_process() {
  [[ $(ps -o command= -p "$1" 2>/dev/null) == *watchd.sh* ]]
}

# Usage: live_keys [SLUG]. Prints the key of each subscription of SLUG (or of all) whose session
# runs.
live_keys() {
  local file session slug
  for file in "$WATCHD_DIR"/subs/*.json; do
    read -r session slug < <(jq -r '"\(.session_pid) \(.slug)"' "$file" 2>/dev/null) || continue
    if [[ -z ${1:-} || $slug == "$1" ]] && watch_alive "$session"; then basename "$file" .json; fi
  done
}

# Usage: remove_record SLUG KEY REASON [ERROR FILE]. The caller holds the lock of the record.
# The error file goes to the client. The lock makes sure that the client sees the error before it
# sees that the record is gone. The owner file keeps the session of the results, so that only the
# next client of that session gets them.
remove_record() {
  local sub=$WATCHD_DIR/subs/$2.json session workspace stage=stopped
  if [[ -n ${4:-} ]]; then
    cp "$4" "$WATCHD_DIR/inbox/$2.error"
    watch_event_log "$(jq -c --arg error "$(head -n1 "$4")" --argjson now "$(date +%s)" \
      --slurpfile engine <(cat "$WATCH_ENGINE_DIR/$2.json" 2>/dev/null) '
      {time: $now, type: "stopped", slug, key, mode,
       title: (if .mode == "hub" then null else $engine[0].mrs[.mrs[0] | tostring].title end),
       error: $error}' "$sub")"
  fi
  session=$(jq -r .session_pid "$sub" 2>/dev/null)
  if [[ -n $session ]]; then echo "$session" >"$WATCHD_DIR/inbox/$2.owner"; fi
  if [[ $(jq -r .mode "$sub" 2>/dev/null) == review ]]; then watch_items_move "$2" "$1"; fi
  workspace=$(jq -r '.herdr_workspace // empty' "$sub" 2>/dev/null)
  rm -f "$sub" "$WATCHD_DIR/poke/$2" "$WATCHD_DIR/rounds/$2" "$WATCHD_DIR/rounds/$2.poked"
  watch_log "$1" "$2" "subscription removed: $3"
  if [[ -n $workspace ]]; then
    if [[ $3 == "all MRs merged or closed" ]]; then stage=done; fi
    watch_workspace_update "$workspace" --arg stage "$stage" '.stage = $stage'
  fi
}

# Usage: end_sub SLUG KEY REASON [ERROR FILE]
end_sub() {
  local sub=$WATCHD_DIR/subs/$2.json
  watch_lock "$sub.lock" || return
  remove_record "$@"
  watch_unlock "$sub.lock"
}

# Usage: end_if_due FILE NOW. Ends the subscription if its session is gone, or if it has no client
# for the limit. The check is under the lock, so a new record of the key stays.
end_if_due() {
  local file=$1 now=$2 key session slug client client_at reason=''
  key=$(basename "$file" .json)
  watch_lock "$file.lock" || return
  if read -r session slug client client_at < <(jq -r \
    '"\(.session_pid) \(.slug) \(.client_pid) \(.client_at)"' "$file" 2>/dev/null); then
    if ! watch_alive "$session"; then
      reason="session $session is gone"
    elif ! watch_alive "$client" && ((now - client_at > client_seconds)); then
      reason="no client for $client_seconds seconds"
    fi
    if [[ -n $reason ]]; then remove_record "$slug" "$key" "$reason"; fi
  fi
  watch_unlock "$file.lock"
}

# Removes the results of ended subscriptions whose session is gone, and results with no record and
# no owner. The open items of a stack or review key are results. The hub keeps its items: the
# present rules close them, and a new hub session gets them.
sweep() {
  local file key sub owner
  local stack_key='-[0-9a-f]{12}(-review-[0-9]+)?$'
  for file in "$WATCHD_DIR"/inbox/*.jsonl "$WATCHD_DIR"/inbox/*.error \
    "$WATCHD_DIR"/items/*.json; do
    [[ $file == *.last.jsonl ]] && continue
    key=$(basename "${file%.*}")
    [[ $file == */items/* && ! $key =~ $stack_key ]] && continue
    sub=$WATCHD_DIR/subs/$key.json
    [[ -f $sub ]] && continue
    watch_lock "$sub.lock" || continue
    owner=$(cat "$WATCHD_DIR/inbox/$key.owner" 2>/dev/null)
    if [[ -f $sub ]] || { [[ -n $owner ]] && watch_alive "$owner"; }; then
      watch_unlock "$sub.lock"
      continue
    fi
    rm -f "$WATCHD_DIR/inbox/$key.jsonl" "$WATCHD_DIR/inbox/$key.error" \
      "$WATCHD_DIR/inbox/$key.owner" "$WATCHD_DIR/inbox/$key.last.jsonl"
    if [[ $key =~ $stack_key ]]; then rm -f "$WATCHD_DIR/items/$key.json"; fi
    watch_unlock "$sub.lock"
    watch_log "" "$key" "results of an ended subscription removed"
  done
}

# Usage: assign_rows KEY EVENTS_FILE. Writes EVENTS_FILE.rows: each event gets row, the number of
# its open item. An event with a new item key opens a new item. An event with no item key gets a
# new number.
assign_rows() {
  local items=$WATCHD_DIR/items/$1.json rc=0
  watch_lock "$items.lock" || return
  jq -n --slurpfile items <(cat "$items" 2>/dev/null) --slurpfile events "$2" \
    --argjson now "$(date +%s)" '
    reduce $events[] as $e ({items: ($items[0] // {next: 1, items: []}), out: []};
      if $e.item then
        ([.items.items[].item] | index($e.item)) as $i
        | if $i != null then
            .out += [$e + {row: .items.items[$i].n}]
            | if $e.kind == "unaddressed" then . else .items.items[$i].event = $e end
          else
            .items.next as $n
            | .items.items += [{n: $n, item: $e.item, owner: "daemon", iid: $e.iid,
                title: $e.title, url: $e.url, what: null, result: null, since: $now, event: $e}]
            | .items.next += 1
            | .out += [$e + {row: $n}]
          end
      else
        .out += [$e + {row: .items.next}] | .items.next += 1
      end)' >"$items.assign" \
    && jq '.items' "$items.assign" >"$items.tmp" && mv "$items.tmp" "$items" \
    && jq -c '.out[]' "$items.assign" >"$2.rows" || rc=1
  rm -f "$items.assign"
  watch_unlock "$items.lock"
  return "$rc"
}

# Usage: prune_items SLUG KEY MODE. After a check: removes each daemon item whose key is not in the
# present list of the engine state. A hub item of a review key uses the present list of the hub
# engine state, and stays if there is none.
prune_items() {
  local items=$WATCHD_DIR/items/$2.json present hub=null
  [[ -f $items ]] || return 0
  present=$(jq -c '.present // empty' "$WATCH_ENGINE_DIR/$2.json" 2>/dev/null)
  [[ -n $present ]] || return 0
  if [[ $3 != hub ]]; then
    hub=$(jq -c '.present // null' "$WATCH_ENGINE_DIR/$1.json" 2>/dev/null)
    [[ -n $hub ]] || hub=null
  fi
  watch_lock "$items.lock" || return 0
  jq --argjson present "$present" --argjson hub "$hub" --arg mode "$3" '
    .items |= map(select(.owner == "model"
      or (if $mode != "hub" and (.item | test("^(todo|note|main-failed):"))
          then $hub == null or (.item | IN($hub[]))
          else .item | IN($present[]) end)))' "$items" >"$items.tmp" && mv "$items.tmp" "$items"
  watch_unlock "$items.lock"
}

# Usage: route SLUG KEY MODE EVENTS_FILE. The events get their rows. Then they go to the event
# log, then to the inbox.
route() {
  local inbox=$WATCHD_DIR/inbox/$2.jsonl now
  # The engine saved its state: events that do not go out now are lost.
  if ! assign_rows "$2" "$4"; then
    watch_log "$1" "$2" "no rows: the items file is not readable"
    cp "$4" "$4.rows"
  fi
  now=$(date +%s)
  watch_event_log "$(jq -c --arg slug "$1" --arg key "$2" --arg mode "$3" --argjson now "$now" '
    {time: $now, round: "\($key)-\($now)", type: "event", slug: $slug, key: $key, mode: $mode,
     event: .,
     sound: (if (.kind | IN("todo", "note", "default-failed", "comment", "conflict"))
         or (.kind == "pipeline" and has("jobs"))
       then "request" else "none" end)}' "$4.rows")"
  watch_lock "$inbox.lock" || return
  cat "$4.rows" >>"$inbox"
  watch_unlock "$inbox.lock"
  watch_log "$1" "$2" "routed $(wc -l <"$4" | tr -d ' ') event(s)"
}

# Usage: end_mrs SLUG KEY EVENTS_FILE. Adds the MRs of the merged and closed events to ended_mrs.
# If all MRs ended, the subscription ends. Its inbox stays until the client takes it.
end_mrs() {
  local sub=$WATCHD_DIR/subs/$2.json ended
  ended=$(jq -sc '[.[] | select(.kind == "merged" or .kind == "closed") | .iid]' "$3")
  [[ $ended == "[]" ]] && return 0
  watch_lock "$sub.lock" || return 0
  if [[ -f $sub ]] && jq --argjson ended "$ended" '.ended_mrs = (.ended_mrs + $ended | unique)' \
    "$sub" >"$sub.tmp" && mv "$sub.tmp" "$sub" \
    && [[ $(jq '.mrs - .ended_mrs | length' "$sub") == 0 ]]; then
    remove_record "$1" "$2" "all MRs merged or closed"
  fi
  watch_unlock "$sub.lock"
}

# Usage: check SLUG KEY ROUND_DIR. One engine run for the subscription KEY. Returns 4 for a
# network error.
check() {
  local slug=$1 key=$2 round=$3 mode repo iid rc=0 fails args poke
  read -r mode repo < <(field "$key" '"\(.mode) \(.repo)"') || return 0
  poke=$(cat "$WATCHD_DIR/poke/$key" 2>/dev/null)
  rm -f "$WATCHD_DIR/poke/$key"
  args=(--repo "$repo")
  case $mode in
    hub) args+=(${skip[@]+"${skip[@]}"}) ;;
    stack) for iid in $(field "$key" '.mrs[]'); do args+=(--mr "$iid"); done ;;
    review) args+=(--review --mr "$(field "$key" '.mrs[0]')") ;;
  esac
  WATCH_MR_CACHE=$round "$engine" "${args[@]}" >"$round/out" 2>"$round/err" || rc=$?
  case $rc in
    0)
      rm -f "$fails_dir/$key"
      if [[ -s $round/out ]]; then route "$slug" "$key" "$mode" "$round/out"; fi
      prune_items "$slug" "$key" "$mode"
      if [[ -s $round/out ]]; then end_mrs "$slug" "$key" "$round/out"; fi
      ;;
    4) watch_log "$slug" "$key" "network error: $(head -n1 "$round/err")" ;;
    5)
      watch_log "$slug" "$key" "error: $(head -n1 "$round/err")"
      end_sub "$slug" "$key" "permanent error" "$round/err"
      ;;
    *)
      fails=$(($(cat "$fails_dir/$key" 2>/dev/null || echo 0) + 1))
      echo "$fails" >"$fails_dir/$key"
      watch_log "$slug" "$key" "error $fails of 5: $(head -n1 "$round/err")"
      if ((fails >= 5)); then
        rm -f "$fails_dir/$key"
        end_sub "$slug" "$key" "5 errors in a row" "$round/err"
      fi
      ;;
  esac
  if [[ -f $WATCHD_DIR/subs/$key.json ]]; then
    echo $(($(cat "$WATCHD_DIR/rounds/$key" 2>/dev/null || echo 0) + 1)) \
      >"$WATCHD_DIR/rounds/$key"
    if [[ -n $poke ]]; then echo "$poke" >"$WATCHD_DIR/rounds/$key.poked"; fi
  fi
  return $((rc == 4 ? 4 : 0))
}

# Usage: repo_loop SLUG. Runs in a background subshell, until the repo has no live subscription.
repo_loop() {
  local slug=$1 keys key round network interval
  fails_dir=$(mktemp -d)
  # A stop request ends the loop after the current check, so that the check routes its events.
  stopping=0
  trap 'if [[ -n $sleeper ]]; then kill "$sleeper" 2>/dev/null; fi; rm -rf "$fails_dir"' EXIT
  trap 'stopping=1' TERM
  loop_stop() {
    rm -f "$WATCHD_DIR/repos/$slug.pid"
    watch_log "$slug" "" "repo loop stop"
    exit 0
  }
  # True if a subscription of this repo asks for a round now, or the loop must stop.
  nap_interrupted() {
    local file
    ((stopping)) && return 0
    for file in "$WATCHD_DIR"/poke/*; do
      if [[ $(field "$(basename "$file")" .slug) == "$slug" ]]; then return 0; fi
    done
    [[ -e $WATCHD_DIR/restart ]]
  }
  # The wait for the network has no limit, but a restart, a stop, or the end of the subscriptions
  # of the repo ends it.
  exit_if_orphaned() {
    if ((stopping)) || [[ -e $WATCHD_DIR/restart || -z $(live_keys "$slug") ]]; then loop_stop; fi
  }
  watch_log "$slug" "" "repo loop start"
  while :; do
    keys=$(live_keys "$slug")
    if ((stopping)) || [[ -z $keys || -e $WATCHD_DIR/restart ]]; then loop_stop; fi
    skip=()
    # A live review key takes the open hub items of its MR.
    for key in $keys; do
      if [[ $(field "$key" .mode) == review ]]; then
        skip+=(--skip-mr "$(field "$key" '.mrs[0]')")
        watch_items_move "$slug" "$key" "$(field "$key" '.mrs[0]')"
      fi
    done
    round=$(mktemp -d)
    network=0
    for key in $keys; do
      check "$slug" "$key" "$round" || network=1
      if ((stopping)); then break; fi
    done
    rm -rf "$round"
    touch "$WATCHD_DIR/repos/$slug.pid"
    watch_log "$slug" "" "round done: $(wc -w <<<"$keys" | tr -d ' ') subscription(s)"
    if ((stopping)); then loop_stop; fi
    WATCH_HOST=$(remote_host "$(git -C "$(field "${keys%%$'\n'*}" .repo)" remote get-url origin \
      2>/dev/null)")
    # With the network up, as for HTTP 502, the normal wait follows.
    if ((network)) && ! online "$WATCH_HOST"; then wait_online "$WATCH_HOST"; continue; fi
    interval=$(for key in $keys; do field "$key" .interval; done | sort -n | head -n1)
    nap "${interval:-120}"
  done
}

# Removes the event log lines and the engine states with no record that are older than 7 days.
prune() {
  local cut file
  cut=$(($(date +%s) - 7 * 86400))
  if watch_lock "$WATCHD_DIR/events.lock"; then
    if [[ -f $WATCHD_DIR/events.jsonl ]]; then
      jq -c --argjson cut "$cut" 'select(.time >= $cut)' "$WATCHD_DIR/events.jsonl" \
        >"$WATCHD_DIR/events.tmp" && mv "$WATCHD_DIR/events.tmp" "$WATCHD_DIR/events.jsonl"
    fi
    watch_unlock "$WATCHD_DIR/events.lock"
  fi
  for file in "$WATCH_ENGINE_DIR"/*.json; do
    if [[ ! -f $WATCHD_DIR/subs/$(basename "$file") ]] && (($(stat -f %m "$file") < cut)); then
      rm -f "$file"
      watch_log "" "$(basename "$file" .json)" "old engine state removed"
    fi
  done
}

stop() {
  local file pid
  if [[ -n $sleeper ]]; then kill "$sleeper" 2>/dev/null; fi
  for file in "$WATCHD_DIR"/repos/*.pid; do
    pid=$(cat "$file" 2>/dev/null)
    if [[ -n $pid ]] && is_daemon_process "$pid"; then kill "$pid" 2>/dev/null; fi
    rm -f "$file"
  done
  if [[ $(cat "$WATCHD_DIR/daemon.pid" 2>/dev/null) == "$$" ]]; then
    rm -f "$WATCHD_DIR/daemon.pid"
  fi
  watch_log "" "" "daemon stop $$"
}

# The log grows with each round. The clients and this daemon append to it, so it shrinks in place.
log=$WATCHD_DIR/watchd.log
if [[ -f $log ]] && (($(wc -l <"$log") > 10000)); then
  tail -n 5000 "$log" >"$log.tmp" && cat "$log.tmp" >"$log"
  rm -f "$log.tmp"
fi
# The hash first: a client that sees the PID compares the hash.
hash=$(watch_scripts_hash)
seen_hash=$hash
echo "$hash" >"$WATCHD_DIR/daemon.hash"
echo $$ >"$WATCHD_DIR/daemon.pid"
watch_log "" "" "daemon start $$"
trap stop EXIT
trap 'exit 0' TERM INT
idle_since=$(date +%s)
pruned_at=0
while :; do
  # chezmoi writes the files one by one: a hash that stays for one tick is the full update.
  new_hash=$(watch_scripts_hash)
  if [[ $new_hash != "$hash" && $new_hash == "$seen_hash" ]]; then touch "$WATCHD_DIR/restart"; fi
  seen_hash=$new_hash
  if [[ -e $WATCHD_DIR/restart ]]; then
    watch_log "" "" "restart: waiting for the repo loops"
    wait
    rm -f "$WATCHD_DIR/restart"
    exec "$WATCH_BIN/watchd.sh"
  fi
  now=$(date +%s)
  if ((now - pruned_at >= 3600)); then
    prune
    pruned_at=$now
  fi
  for file in "$WATCHD_DIR"/subs/*.json; do
    end_if_due "$file" "$now"
  done
  sweep
  slugs=$(for key in $(live_keys); do field "$key" .slug; done | sort -u)
  if [[ -n $slugs ]]; then
    idle_since=$now
  elif ((now - idle_since >= idle_seconds)); then
    watch_log "" "" "idle stop"
    exit 0
  fi
  for slug in $slugs; do
    pid=$(cat "$WATCHD_DIR/repos/$slug.pid" 2>/dev/null)
    if [[ -n $pid ]] && is_daemon_process "$pid"; then continue; fi
    repo_loop "$slug" &
    echo $! >"$WATCHD_DIR/repos/$slug.pid"
  done
  bg_sleep "$tick"
done
