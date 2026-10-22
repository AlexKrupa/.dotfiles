#!/usr/bin/env bash
# Usage: watch.sh [--repo PATH] [--interval SECONDS] [--once] [--fresh] [--review] [--mr IID]...
#        watch.sh unsubscribe [--repo PATH] [--review] [--mr IID]...
#        watch.sh status
# The client of the watch daemon watchd.sh, for the background task of a session. It starts the
# daemon if no daemon runs, writes its subscription, waits for the events of the subscription,
# and prints one JSON line for each event. The flags, the modes, and the events are as in the
# header of watch-gitlab.sh.
# The subscription stays live after the client exits, until the session exits: the events of the
# time with no client wait for the next client.
# unsubscribe: end the subscription of the repo and mode.
# status: the daemon PID, the last poll of each repo, and one TSV line for each subscription: key,
# mode, MRs, live or dead session, inbox line count.
# Exit codes: 0 events, 1 error, 3 a new client or session replaced this one
set -euo pipefail

die() { echo "watch: $1" >&2; exit 1; }
# shellcheck source=watch-state.sh
source "$HOME/.config/agents/bin/watch-state.sh"

command=wait
case ${1:-} in
  unsubscribe | status) command=$1; shift ;;
esac
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
mkdir -p "$WATCHD_DIR"/{subs,inbox,poke,rounds,repos}
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
    lines=0
    [[ -f $WATCHD_DIR/inbox/$key.jsonl ]] && lines=$(wc -l <"$WATCHD_DIR/inbox/$key.jsonl")
    live=dead
    watch_alive "$(jq -r .session_pid "$file")" && live=live
    jq -r --arg live "$live" --arg lines "${lines// /}" '[.key, .mode,
        ([.mrs[] | tostring] | join(",") | if . == "" then "-" else . end), $live, $lines]
      | @tsv' "$file"
  done
  exit 0
fi

cd "$repo" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $repo"
top=$(git rev-parse --show-toplevel)
slug=$("$WATCH_BIN/repo-slug.sh")
key=$(watch_key "$top" "$review" ${mrs[@]+"${mrs[@]}"})
sub=$WATCHD_DIR/subs/$key.json
inbox=$WATCHD_DIR/inbox/$key.jsonl
error=$WATCHD_DIR/inbox/$key.error

if [[ $command == unsubscribe ]]; then
  watch_lock "$sub.lock" || exit 1
  rm -f "$sub" "$inbox" "$error" "$WATCHD_DIR/poke/$key" "$WATCHD_DIR/rounds/$key"
  watch_unlock "$sub.lock"
  watch_log "$slug" "$key" "unsubscribed"
  exit 0
fi

# The lock makes sure that two clients do not start two daemons.
start_daemon() {
  watch_lock "$WATCHD_DIR/start.lock" || exit 1
  if ! daemon_alive; then
    rm -f "$WATCHD_DIR/daemon.pid"
    nohup "$WATCH_BIN/watchd.sh" </dev/null >>"$WATCHD_DIR/watchd.log" 2>&1 &
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

if ((review)); then mode=review; elif ((${#mrs[@]})); then mode=stack; else mode=hub; fi
session=$(watch_session_pid)
((fresh)) && rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/watch-gitlab/$key.json"
start_daemon
watch_lock "$sub.lock" || exit 1
jq -n --arg key "$key" --arg slug "$slug" --arg repo "$top" --arg mode "$mode" \
  --argjson interval "$interval" --argjson session "$session" --argjson client $$ \
  --argjson now "$(date +%s)" '$ARGS.positional as $mrs
  | {key: $key, slug: $slug, repo: $repo, mode: $mode, mrs: ($mrs | map(tonumber)),
     interval: $interval, session_pid: $session, client_pid: $client, client_at: $now,
     replaced_sessions: [], ended_mrs: []}' --args ${mrs[@]+"${mrs[@]}"} >"$sub.tmp"
mv "$sub.tmp" "$sub"
watch_unlock "$sub.lock"
watch_log "$slug" "$key" "subscribed: $mode ${mrs[*]+${mrs[*]}}"

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
    rm -f "$error"
    watch_unlock "$sub.lock"
    exit 1
  fi
  watch_unlock "$sub.lock"
  watch_lock "$inbox.lock" || exit 1
  [[ -s $inbox ]] && mv "$inbox" "$tmp"
  watch_unlock "$inbox.lock"
  if [[ -s $tmp ]]; then cat "$tmp"; exit 0; fi
  ((ended)) && die "the subscription ended"
  daemon_alive || start_daemon
  watch_sub_update "$key" --argjson now "$(date +%s)" '.client_at = $now' || true
  exit_if_orphaned
  sleep "${WATCH_CLIENT_TICK:-3}"
done
