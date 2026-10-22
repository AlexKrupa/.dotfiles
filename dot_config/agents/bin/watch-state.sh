# State paths, keys, and locks of the watch client, the watch daemon, and the check engine.
# Source this file. WATCH_BIN is the folder of the watch scripts.

WATCH_BIN=${WATCH_BIN:-$HOME/.config/agents/bin}
WATCHD_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/watchd

# Usage: watch_key REPO REVIEW(0|1) [IID]...
# The repo slug. With MRs, also the worktree hash, so that a stack watch and the hub watch of one
# repo have different keys. In review mode, also the MR, so that each reviewed MR has its own key.
watch_key() {
  local repo=$1 review=$2 key top
  shift 2
  key=$(cd "$repo" && "$WATCH_BIN/repo-slug.sh") || return
  if (($#)); then
    top=$(git -C "$repo" rev-parse --show-toplevel) || return
    key=$key-$(printf %s "$top" | shasum | cut -c1-12)
  fi
  if ((review)); then key=$key-review-$1; fi
  echo "$key"
}

# `ps`, not `kill -0`: `kill -0` fails on processes of root.
watch_alive() {
  ps -p "$1" >/dev/null 2>&1
}

# The Claude Code process that runs the caller. Its life is the life of the subscription.
watch_session_pid() {
  local p=$PPID comm
  if [[ -n ${WATCH_SESSION_PID:-} ]]; then echo "$WATCH_SESSION_PID"; return; fi
  while ((p > 1)); do
    comm=$(ps -o comm= -p "$p") || break
    if [[ ${comm##*/} == claude ]]; then echo "$p"; return; fi
    p=$(ps -o ppid= -p "$p" | tr -d ' ')
  done
  # The parent dies with the client, so the subscription ends soon after each client.
  watch_log "" "" "no claude process above PID $PPID: the session is PID $PPID"
  echo "$PPID"
}

# Usage: lock_stale DIR. True if DIR is older than 30 seconds.
lock_stale() {
  (($(date +%s) - $(stat -f %m "$1" 2>/dev/null || date +%s) > 30))
}

# A mkdir lock: macOS has no flock. Waits up to 10 seconds. A lock older than 30 seconds is of a
# process that died before its unlock. Only one waiter at a time breaks it: a second waiter must
# not remove the new lock of the first.
watch_lock() {
  local try
  for try in $(seq 100); do
    mkdir "$1" 2>/dev/null && return 0
    if lock_stale "$1"; then
      if mkdir "$1.break" 2>/dev/null; then
        if lock_stale "$1"; then rm -rf "$1"; fi
        rmdir "$1.break"
        continue
      fi
      if lock_stale "$1.break"; then rmdir "$1.break" 2>/dev/null; fi
    fi
    sleep 0.1
  done
  echo "watch: no lock after 10 seconds: $1" >&2
  return 1
}

watch_unlock() {
  rm -rf "$1"
}

# A different hash means new daemon code, for example after a chezmoi update.
watch_scripts_hash() {
  cat "$WATCH_BIN"/watchd.sh "$WATCH_BIN"/watch-gitlab.sh "$WATCH_BIN"/watch-lib.sh \
    "$WATCH_BIN"/watch-state.sh "$WATCH_BIN"/repo-slug.sh 2>/dev/null | shasum | cut -c1-40
}

# Usage: watch_log SLUG KEY MESSAGE. An empty SLUG or KEY prints `-`.
watch_log() {
  printf '%s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:--}" "${2:--}" "$3" \
    >>"$WATCHD_DIR/watchd.log"
}

# Usage: watch_sub_update KEY [JQ OPTION]... FILTER
# Changes the subscription record of KEY with a jq filter, under the lock of the key. Returns 1 if
# the record does not exist.
watch_sub_update() {
  local file=$WATCHD_DIR/subs/$1.json rc=0
  shift
  watch_lock "$file.lock" || return
  if [[ -f $file ]]; then
    jq "$@" "$file" >"$file.tmp" && mv "$file.tmp" "$file" || rc=1
  else
    rc=1
  fi
  watch_unlock "$file.lock"
  return "$rc"
}
