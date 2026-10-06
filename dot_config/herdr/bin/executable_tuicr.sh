#!/bin/sh
# tuicr in a split next to an agent pane, and its comments sent back to it.
#
#   tuicr.sh branch   review the branch against its stack parent, or refresh
#                     the open `branch` pane
#   tuicr.sh mr       open the tuicr target selector, for MRs and `:submit`
#   tuicr.sh send     from a `branch` pane: send its comments to the agent
#
# `branch` and `mr` split the focused pane. A `branch` split runs `tuicr.sh
# pane`, which keeps the agent pane ID, the repo and its own PID in a state dir
# named by its own pane ID. `send` looks up that dir from the focused pane, so
# it ignores `mr` panes and any tuicr that this script did not open.
#
# tuicr resolves `-r` to commit IDs at startup, and neither `:e` nor
# `diff_watch_interval_ms` resolves it again. So `branch` from a `branch` pane,
# or from its agent pane, restarts tuicr in that pane to show new commits. The
# session slug holds the commit IDs, so after new commits or an amend tuicr
# opens a new session. The refresh sends the unsent comments first, so they do
# not stay behind in the old session.
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
# POSIX sh, not fish: this is key-bound (see lazygit.sh).

state_root=${TMPDIR:-/tmp}/herdr-tuicr
sent_root=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-tuicr/sent
active_sessions="$HOME/Library/Application Support/tuicr/reviews/active_sessions.json"

state_dir() { printf '%s/%s' "$state_root" "$(printf '%s' "$1" | tr : _)"; }

# The state dir of the `branch` pane $1, or of a live `branch` pane opened next
# to agent pane $1. Empty if there is none.
branch_pane_dir() {
  dir=$(state_dir "$1")
  if [ -f "$dir/agent" ]; then
    printf '%s' "$dir"
    return
  fi
  for agent_file in "$state_root"/*/agent; do
    [ "$(cat "$agent_file" 2>/dev/null)" = "$1" ] || continue
    dir=${agent_file%/agent}
    # A killed pane skips its EXIT trap and leaves its dir behind.
    if kill -0 "$(cat "$dir/pid")" 2>/dev/null; then
      printf '%s' "$dir"
      return
    fi
  done
}

# Sends the comments of the `branch` pane with state dir $1 to its agent. A
# subshell, so `exit` and `cd` stay inside it.
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

  # Same layout as the tuicr export. A review comment has location "review"
  # and no anchor.
  text=$(printf '%s' "$new" | jq -r '
    "I reviewed your code and have the following comments. Please address them.\n\n"
    + (to_entries | map("\(.key + 1). "
        + (if .value.location == "review" then "" else "`\(.value.location)` - " end)
        + .value.content) | join("\n"))')

  if ! err=$(herdr agent prompt "$agent" "$text" 2>&1 >/dev/null); then
    herdr notification show "tuicr comments not sent" \
      --body "$(printf '%s' "$err" | jq -r '.error.message? // .')" --sound request >/dev/null
    exit 1
  fi
  jq --argjson new "$new" '. + ($new | map({(.id): .content}) | add)' "$sent" \
    >"$sent.tmp" && mv "$sent.tmp" "$sent"
)

# The pane closes when this script exits. Wait, so the error stays readable.
fail() {
  printf '%s\n\nPress Enter to close.' "$1" >&2
  read -r _
  exit 1
}

case $1 in
  branch | mr)
    [ -n "$HERDR_ACTIVE_PANE_ID" ] || exit 0
    if [ "$1" = branch ]; then
      dir=$(branch_pane_dir "$HERDR_ACTIVE_PANE_ID")
      if [ -n "$dir" ]; then
        send_comments "$dir" || exit 1
        tuicr_pid=$(pgrep -P "$(cat "$dir/pid")" -x tuicr) || exit 0
        touch "$dir/refresh"
        exec kill "$tuicr_pid"
      fi
      cmd="exec '$0' pane $HERDR_ACTIVE_PANE_ID"
    else
      cmd="exec tuicr"
    fi
    # PATH because HERDR_PANE_CMD skips conf.d (see lazygit.sh).
    exec herdr pane split --pane "$HERDR_ACTIVE_PANE_ID" --direction right --focus \
      --cwd "${HERDR_ACTIVE_PANE_CWD:-$PWD}" --env "PATH=$PATH" \
      --env "HERDR_PANE_CMD=$cmd" >/dev/null
    ;;

  pane)
    dir=$(state_dir "$HERDR_PANE_ID")
    mkdir -p "$dir" || fail "Cannot create $dir"
    trap 'rm -rf "$dir"' EXIT
    printf '%s\n' "$2" >"$dir/agent"
    printf '%s\n' "$PWD" >"$dir/repo"
    printf '%s\n' "$$" >"$dir/pid"

    while :; do
      rm -f "$dir/refresh"
      # Resolved again on each refresh: a rebase can change the parent.
      ctx=$(~/.config/ai/bin/git-diff-context.sh --parent-only 2>&1) || fail "$ctx"
      parent=$(printf '%s\n' "$ctx" | sed -n 's/^parent: //p')
      [ -n "$parent" ] || fail "$ctx"

      # Three dots: tuicr diffs from the merge base. With two dots it diffs from
      # the parent tip, so new parent commits show up as reverted.
      tuicr -r "$parent...HEAD" 2>"$dir/stderr" && break
      [ -f "$dir/refresh" ] || fail "$(cat "$dir/stderr")"
    done
    ;;

  send)
    send_comments "$(state_dir "$HERDR_ACTIVE_PANE_ID")"
    ;;

  *)
    echo "usage: tuicr.sh branch | mr | send" >&2
    exit 2
    ;;
esac
