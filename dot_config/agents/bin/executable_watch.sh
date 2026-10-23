#!/usr/bin/env bash
# Usage: watch.sh [--repo PATH] [--interval SECONDS] [--once] [--fresh] [--review] [--mr IID]...
#        watch.sh unsubscribe [--repo PATH] [--review] [--mr IID]...
#        watch.sh status
#        watch.sh kind KIND [--workspace ID]
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
# sidebar. The workspace is ID, else $HERDR_WORKSPACE_ID. Outside herdr it does nothing. With no
# live subscription in the workspace, it also clears the stage. A subscription in a workspace with
# no kind sets the kind of its mode: mine for a stack, review, or hub.
# In herdr, the subscription also writes its stage and its needs-you values to the workspace.
# Exit codes: 0 events, 1 error, 3 a new client or session replaced this one
set -euo pipefail

die() { echo "watch: $1" >&2; exit 1; }
# shellcheck source=watch-state.sh
source "$HOME/.config/agents/bin/watch-state.sh"

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
      watch_herdr_tokens "$workspace" "watch_kind=$kind"
      exit 0
    fi
  done
  watch_herdr_tokens "$workspace" "watch_kind=$kind" watch_stage= watch_needs=
  exit 0
fi

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
slug=$("$WATCH_BIN/repo-slug.sh")
key=$(watch_key "$top" "$review" ${mrs[@]+"${mrs[@]}"})
sub=$WATCHD_DIR/subs/$key.json
inbox=$WATCHD_DIR/inbox/$key.jsonl
error=$WATCHD_DIR/inbox/$key.error
owner=$WATCHD_DIR/inbox/$key.owner

session=$(watch_session_pid)
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
  rm -f "$sub" "$inbox" "$error" "$owner" "$WATCHD_DIR/poke/$key" "$WATCHD_DIR/rounds/$key" \
    "$WATCHD_DIR/rounds/$key.poked"
  if [[ -n $workspace ]]; then watch_herdr_tokens "$workspace" watch_stage=stopped watch_needs=; fi
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

if ((review)); then mode=review; elif ((${#mrs[@]})); then mode=stack; else mode=hub; fi
# The daemon writes the text of the poke to this file after the check of the key.
poked=$WATCHD_DIR/rounds/$key.poked
poke_token=$$-$(date +%s)
((fresh)) && rm -f "$WATCH_ENGINE_DIR/$key.json"
# New scripts, for example after a chezmoi update: the daemon exits after its current round, and
# this client starts the new daemon. The state is on disk, so no event is lost.
if daemon_alive && [[ $(cat "$WATCHD_DIR/daemon.hash" 2>/dev/null) != "$(watch_scripts_hash)" ]]
then
  watch_log "" "" "new scripts: restart"
  touch "$WATCHD_DIR/restart"
  for _ in $(seq 300); do daemon_alive || break; sleep 0.2; done
fi
start_daemon

replaced() { echo "watch: a new client or session replaced this one" >&2; exit 3; }
# Usage: default_kind KIND. The role skills set their kind before they watch. A watch that started
# before its skill set a kind gets the kind of its mode.
default_kind() {
  local answer
  command -v herdr >/dev/null || return 0
  answer=$(herdr workspace get "$HERDR_WORKSPACE_ID" 2>/dev/null) || return 0
  if ! jq -e '.result.workspace.tokens.watch_kind' <<<"$answer" >/dev/null 2>&1; then
    watch_herdr_tokens "$HERDR_WORKSPACE_ID" "watch_kind=$1"
  fi
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
    --argjson now "$(date +%s)" --argjson old "$old" --argjson replaced "$replaced_session" \
    --arg workspace "${HERDR_WORKSPACE_ID:-}" '
    ($ARGS.positional | map(tonumber)) as $mrs | ($old.ended_mrs // []) as $ended
    | {key: $key, slug: $slug, repo: $repo, mode: $mode, mrs: $mrs, interval: $interval,
       session_pid: $session, client_pid: $client, client_at: $now,
       replaced_sessions: ($old.replaced_sessions // [] | . + [$replaced // empty] | unique),
       ended_mrs: ($ended - ($ended - $mrs))}
      + if $workspace == "" then {} else {herdr_workspace: $workspace} end' \
    --args ${mrs[@]+"${mrs[@]}"} >"$sub.tmp"
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
      cat "$tmp"
      exit 0
    fi
  fi
  ((ended)) && die "the subscription ended"
  daemon_alive || start_daemon
  watch_sub_update "$key" --argjson now "$(date +%s)" '.client_at = $now' || true
  exit_if_orphaned
  sleep "${WATCH_CLIENT_TICK:-3}"
done
