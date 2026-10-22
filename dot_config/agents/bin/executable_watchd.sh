#!/usr/bin/env bash
# Usage: watchd.sh
# The watch daemon: one process for each machine. watch.sh starts it when no daemon runs.
# It runs one poll loop for each repo with a live subscription. A subscription is live while its
# session process runs. Each round runs the check engine (watch-gitlab.sh --once) for each live
# subscription of the repo, and appends the events to the inbox of the subscription. The hub check
# skips the MRs of the live review subscriptions. The fetched MRs go to a cache of the round, so
# two subscriptions of one MR get one fetch. The round interval is the smallest --interval of the
# subscriptions of the repo.
# A network error does not count: the loop waits for the network, with no limit. A permanent
# error, or 5 other errors in a row, end the subscription, and its client gets the error text.
# With no subscription for 10 minutes, the daemon exits.
# State and log: $WATCHD_DIR, see watch-state.sh. The log has one line for each event of the
# daemon: time, repo slug, subscription key, message.
# Test seams: WATCHD_TICK (main loop seconds), WATCHD_IDLE_SECONDS, WATCHD_ENGINE.
# No `set -e`: an error in one round must not stop the watches of all sessions.
set -uo pipefail

# shellcheck source=watch-lib.sh
source "$HOME/.config/agents/bin/watch-lib.sh"
# shellcheck source=watch-state.sh
source "$HOME/.config/agents/bin/watch-state.sh"

tick=${WATCHD_TICK:-5}
idle_seconds=${WATCHD_IDLE_SECONDS:-600}
engine=${WATCHD_ENGINE:-$WATCH_BIN/watch-gitlab.sh}
shopt -s nullglob
cd / || exit 1
mkdir -p "$WATCHD_DIR"/{subs,inbox,poke,rounds,repos}
sleeper=''
# The wait for the network has no limit.
exit_if_orphaned() { :; }

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

# Usage: end_sub SLUG KEY REASON [ERROR FILE]
# The error file goes to the client. The lock makes sure that the client sees the error before it
# sees that the record is gone.
end_sub() {
  local sub=$WATCHD_DIR/subs/$2.json
  watch_lock "$sub.lock" || return
  if [[ -n ${4:-} ]]; then cp "$4" "$WATCHD_DIR/inbox/$2.error"; fi
  rm -f "$sub" "$WATCHD_DIR/poke/$2" "$WATCHD_DIR/rounds/$2"
  watch_unlock "$sub.lock"
  watch_log "$1" "$2" "subscription removed: $3"
}

# Usage: route SLUG KEY EVENTS FILE
route() {
  local inbox=$WATCHD_DIR/inbox/$2.jsonl
  watch_lock "$inbox.lock" || return
  cat "$3" >>"$inbox"
  watch_unlock "$inbox.lock"
  watch_log "$1" "$2" "routed $(wc -l <"$3" | tr -d ' ') event(s)"
}

# Usage: check SLUG KEY ROUND_DIR. One engine run for the subscription KEY. Returns 4 for a
# network error.
check() {
  local slug=$1 key=$2 round=$3 mode repo iid rc=0 fails args
  read -r mode repo < <(field "$key" '"\(.mode) \(.repo)"') || return 0
  args=(--once --repo "$repo")
  case $mode in
    hub) args+=(${skip[@]+"${skip[@]}"}) ;;
    stack) for iid in $(field "$key" '.mrs[]'); do args+=(--mr "$iid"); done ;;
    review) args+=(--review --mr "$(field "$key" '.mrs[0]')") ;;
  esac
  WATCH_MR_CACHE=$round "$engine" "${args[@]}" >"$round/out" 2>"$round/err" || rc=$?
  case $rc in
    0)
      rm -f "$fails_dir/$key"
      if [[ -s $round/out ]]; then route "$slug" "$key" "$round/out"; fi
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
  fi
  return $((rc == 4 ? 4 : 0))
}

# Usage: repo_loop SLUG. Runs in a background subshell, until the repo has no live subscription.
repo_loop() {
  local slug=$1 keys key round network interval
  fails_dir=$(mktemp -d)
  trap 'if [[ -n $sleeper ]]; then kill "$sleeper" 2>/dev/null; fi; rm -rf "$fails_dir"' EXIT
  trap 'exit 0' TERM
  watch_log "$slug" "" "repo loop start"
  while :; do
    keys=$(live_keys "$slug")
    if [[ -z $keys ]]; then
      rm -f "$WATCHD_DIR/repos/$slug.pid"
      watch_log "$slug" "" "repo loop stop"
      exit 0
    fi
    skip=()
    for key in $keys; do
      if [[ $(field "$key" .mode) == review ]]; then skip+=(--skip-mr "$(field "$key" '.mrs[0]')"); fi
    done
    round=$(mktemp -d)
    network=0
    for key in $keys; do
      check "$slug" "$key" "$round" || network=1
    done
    rm -rf "$round"
    touch "$WATCHD_DIR/repos/$slug.pid"
    watch_log "$slug" "" "round done: $(wc -w <<<"$keys" | tr -d ' ') subscription(s)"
    WATCH_HOST=$(remote_host "$(git -C "$(field "${keys%%$'\n'*}" .repo)" remote get-url origin \
      2>/dev/null)")
    # With the network up, as for HTTP 502, the normal wait follows.
    if ((network)) && ! online "$WATCH_HOST"; then wait_online "$WATCH_HOST"; continue; fi
    interval=$(for key in $keys; do field "$key" .interval; done | sort -n | head -n1)
    nap "${interval:-120}"
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

echo $$ >"$WATCHD_DIR/daemon.pid"
watch_log "" "" "daemon start $$"
trap stop EXIT
trap 'exit 0' TERM INT
idle_since=$(date +%s)
while :; do
  for file in "$WATCHD_DIR"/subs/*.json; do
    key=$(basename "$file" .json)
    read -r session slug < <(jq -r '"\(.session_pid) \(.slug)"' "$file" 2>/dev/null) || continue
    watch_alive "$session" && continue
    end_sub "$slug" "$key" "session $session is gone"
    rm -f "$WATCHD_DIR/inbox/$key.jsonl" "$WATCHD_DIR/inbox/$key.error"
  done
  slugs=$(for key in $(live_keys); do field "$key" .slug; done | sort -u)
  now=$(date +%s)
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
