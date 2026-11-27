#!/bin/sh
# tuicr in a full-height pane on the right edge of the tab of an agent pane, and
# its comments sent back to that agent.
#
#   tuicr.sh branch <pane>   review the branch against its stack parent in a
#                            zoomed pane, or refresh the open `branch` pane
#   tuicr.sh mr <pane>       review the MR of the current branch, for
#                            `:submit`
#   tuicr.sh file <pane> <path> [<line>]
#                            review one file in a zoomed pane, for questions
#                            about the code
#   tuicr.sh send <pane>     from a `branch` or `file` pane: send its comments
#                            to the agent and unzoom the pane
#
# <pane> is the active pane of the multiplexer key binding. `branch` and `mr`
# open a full-height pane on the right edge of its tab. An `mr` pane runs
# `tuicr.sh mr-pane`, which keeps the error of `tuicr mr` on screen, for example
# when the branch has no MR. A `branch` pane runs
# `tuicr.sh pane`, which keeps the agent pane ID, the repo and its own PID in a
# state dir named by its own pane ID. `send` finds that dir from <pane>. It
# ignores `mr` panes and each tuicr that this script did not open. A `file`
# pane runs `tuicr.sh file-pane`, which keeps the same state and a `file` marker.
# `branch` does not restart a `file` pane. From a `file` pane, it opens a
# `branch` pane for the agent of that pane.
#
# tuicr resolves `-r` to commit IDs at startup, and neither `:e` nor
# `diff_watch_interval_ms` resolves it again. So `branch` from a `branch` pane,
# or from its agent pane, restarts tuicr in that pane to show new commits. The
# session slug holds the commit IDs, so after new commits or an amend tuicr
# opens a new session. The refresh sends the unsent comments first. Otherwise
# they stay in the old session.
#
# tuicr 0.27.0 has no hooks and no custom keys, and `--stdout` exports only on
# quit. So `send` reads the saved session with `tuicr review comments`. tuicr
# saves the session on each comment change. tuicr prints the session slug to
# stderr only at startup, and `:commits` can switch to a new session later.
# $active_sessions holds the open session of each tuicr process, so `send`
# looks it up by the PID of the tuicr child.
#
# `send` sends only comments that are new or changed since the last send. It
# records them per session in $sent_root, so the record outlives the pane.
# Clearing the session instead does not work: `clearc` deletes the empty
# session file, the open TUI keeps its copy, and its next save writes the old
# comments back.
#
# POSIX sh, not fish: this is key-bound.

mux=$(dirname "$0")/mux.sh
state_root=${TMPDIR:-/tmp}/tuicr-panes
sent_root=${XDG_STATE_HOME:-$HOME/.local/state}/tuicr-panes/sent
active_sessions="$HOME/Library/Application Support/tuicr/reviews/active_sessions.json"

state_dir() { printf '%s/%s' "$state_root" "$(printf '%s' "$1" | tr : _)"; }

# The state dir of the `branch` pane $1, or of a live `branch` pane opened next
# to agent pane $1. Empty if there is none.
branch_pane_dir() {
  # A killed pane skips its EXIT trap and leaves its dir behind.
  dir=$(state_dir "$1")
  if [ -f "$dir/agent" ] && [ ! -f "$dir/file" ] && kill -0 "$(cat "$dir/pid")" 2>/dev/null; then
    printf '%s' "$dir"
    return
  fi
  for agent_file in "$state_root"/*/agent; do
    [ "$(cat "$agent_file" 2>/dev/null)" = "$1" ] || continue
    dir=${agent_file%/agent}
    [ ! -f "$dir/file" ] || continue
    if kill -0 "$(cat "$dir/pid")" 2>/dev/null; then
      printf '%s' "$dir"
      return
    fi
  done
}

# Sends the comments of the `branch` pane with state dir $1 to its agent. It
# runs in a subshell. `exit` and `cd` do not change the caller.
send_comments() (
  dir=$1
  [ -f "$dir/agent" ] || exit 0
  agent=$(cat "$dir/agent")
  tuicr_pid=$(pgrep -P "$(cat "$dir/pid")" -x tuicr) || exit 0
  slug=$(jq -r --argjson pid "$tuicr_pid" \
    '.sessions[] | select(.pid == $pid) | .slug' "$active_sessions") || exit 1
  [ -n "$slug" ] || exit 0
  repo=$(cat "$dir/repo")
  # A local slug resolves only inside its repo.
  cd "$repo" || exit 1

  mkdir -p "$sent_root" || exit 1
  sent=$sent_root/$(printf '%s\n%s' "$repo" "$slug" | shasum | cut -c1-16).json
  [ -f "$sent" ] || echo '{}' >"$sent"

  # Comments whose id is new or whose content changed: {id: content} in $sent.
  new=$(tuicr review comments --session "$slug" |
    jq -c --slurpfile sent "$sent" '[.[] | select($sent[0][.id] != .content)]') ||
    exit 1
  [ "$new" = "[]" ] && exit 0

  if [ -f "$dir/file" ]; then
    intro="I have the following comments and questions about the code."
  else
    intro="I reviewed your code and have the following comments. Please address them."
  fi
  # Same layout as the tuicr export. A review comment has location "review"
  # and no anchor.
  text=$(printf '%s' "$new" | jq -r --arg intro "$intro" '
    $intro + "\n\n"
    + (to_entries | map("\(.key + 1). "
        + (if .value.location == "review" then "" else "`\(.value.location)` - " end)
        + .value.content) | join("\n"))')

  if ! err=$("$mux" agent-prompt "$agent" "$text" 2>&1 >/dev/null); then
    # Also stderr: a Rex action has no terminal for the notification, and shows stderr.
    printf 'tuicr comments not sent: %s\n' "$err" >&2
    "$mux" notify "tuicr comments not sent" "$err" 2>/dev/null
    exit 1
  fi
  jq --argjson new "$new" '. + ($new | map({(.id): .content}) | add)' "$sent" \
    >"$sent.tmp" && mv "$sent.tmp" "$sent"
)

# Writes the state dir of this pane for agent pane $1 and removes it on exit.
# Sets $dir.
register_pane() {
  # With no pane ID, the state dir is the root, and the EXIT trap removes it.
  pane=$("$mux" pane-current) || fail "Cannot find the pane of this tuicr"
  dir=$(state_dir "$pane")
  mkdir -p "$dir" || fail "Cannot create $dir"
  trap 'rm -rf "$dir"' EXIT
  printf '%s\n' "$1" >"$dir/agent"
  printf '%s\n' "$PWD" >"$dir/repo"
  printf '%s\n' "$$" >"$dir/pid"
}

# The pane closes when this script exits. Wait, so the error stays readable.
fail() {
  printf '%s\n\nPress Enter to close.' "$1" >&2
  read -r _
  exit 1
}

case $1 in
  branch | mr)
    active=${2:-}
    [ -n "$active" ] || exit 0
    if [ "$1" = branch ]; then
      active_dir=$(state_dir "$active")
      [ ! -f "$active_dir/file" ] || active=$(cat "$active_dir/agent")
      dir=$(branch_pane_dir "$active")
      if [ -n "$dir" ]; then
        send_comments "$dir" || exit 1
        tuicr_pid=$(pgrep -P "$(cat "$dir/pid")" -x tuicr) || exit 0
        touch "$dir/refresh"
        exec kill "$tuicr_pid"
      fi
      cmd="exec '$0' pane '$active'"
    else
      cmd="exec '$0' mr-pane"
    fi
    cwd=$("$mux" pane-cwd "$active")
    split=$("$mux" tab-split "$active" "${cwd:-$PWD}" --focus --run "$cmd") || exit 1
    [ "$1" = branch ] || exit 0
    exec "$mux" pane-zoom "$split" on
    ;;

  file)
    active=${2:-}
    [ -n "$active" ] && [ -n "${3:-}" ] || exit 0
    cwd=$("$mux" pane-cwd "$active")
    cmd="exec '$0' file-pane '$active' '$3' '${4:-}'"
    split=$("$mux" tab-split "$active" "${cwd:-$PWD}" --focus --run "$cmd") || exit 1
    exec "$mux" pane-zoom "$split" on
    ;;

  file-pane)
    register_pane "$2"
    printf '%s\n' "$3" >"$dir/file"
    if [ -n "${4:-}" ]; then
      tuicr --file "$3" --line "$4" 2>"$dir/stderr" || fail "$(cat "$dir/stderr")"
    else
      tuicr --file "$3" 2>"$dir/stderr" || fail "$(cat "$dir/stderr")"
    fi
    ;;

  pane)
    register_pane "$2"

    while :; do
      rm -f "$dir/refresh"
      # Resolved again on each refresh: a rebase can change the parent.
      ctx=$(~/.config/agents/bin/git-diff-context.sh --parent-only 2>&1) || fail "$ctx"
      parent=$(printf '%s\n' "$ctx" | sed -n 's/^parent: //p')
      [ -n "$parent" ] || fail "$ctx"

      # Three dots: tuicr diffs from the merge base. With two dots it diffs from
      # the parent tip, so new parent commits show up as reverted.
      tuicr -r "$parent...HEAD" 2>"$dir/stderr" && break
      [ -f "$dir/refresh" ] || fail "$(cat "$dir/stderr")"
    done
    ;;

  mr-pane)
    err=$(mktemp) || fail "Cannot create a temp file"
    trap 'rm -f "$err"' EXIT
    tuicr mr 2>"$err" || fail "$(cat "$err")"
    ;;

  send)
    [ -n "${2:-}" ] || exit 0
    dir=$(state_dir "$2")
    send_comments "$dir" || exit 1
    [ -f "$dir/agent" ] || exit 0
    exec "$mux" pane-zoom "$2" off
    ;;

  *)
    echo "usage: tuicr.sh branch | mr | send <pane> | file <pane> <path> [<line>]" >&2
    exit 2
    ;;
esac
