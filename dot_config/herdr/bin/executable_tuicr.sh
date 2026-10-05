#!/bin/sh
# tuicr in a split next to an agent pane, and its comments sent back to it.
#
#   tuicr.sh branch   review the branch against its stack parent
#   tuicr.sh mr       open the tuicr target selector, for MRs and `:submit`
#   tuicr.sh send     from a `branch` pane: send its comments to the agent
#
# `branch` and `mr` split the focused pane. A `branch` split runs `tuicr.sh
# pane`, which keeps the agent pane ID, the repo and the tuicr stderr in a state
# dir named by its own pane ID. `send` looks up that dir from the focused pane,
# so it ignores `mr` panes and any tuicr that this script did not open.
#
# tuicr 0.27.0 has no hooks and no custom keys, and `--stdout` exports only on
# quit. So `send` reads the saved session with `tuicr review comments`. tuicr
# saves the session on each comment change. tuicr prints the session slug to
# stderr at startup. `tuicr review list` marks the open session `active`, but
# tuicr does not promise to keep that field (agavra/tuicr#368).
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

state_dir() { printf '%s/%s' "$state_root" "$(printf '%s' "$1" | tr : _)"; }

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

    ctx=$(~/.config/ai/bin/git-diff-context.sh 2>&1) || fail "$ctx"
    parent=$(printf '%s\n' "$ctx" | sed -n 's/^parent: //p')
    [ -n "$parent" ] || fail "$ctx"

    tuicr -r "$parent..HEAD" 2>"$dir/stderr" || fail "$(cat "$dir/stderr")"
    ;;

  send)
    dir=$(state_dir "$HERDR_ACTIVE_PANE_ID")
    [ -f "$dir/agent" ] || exit 0
    agent=$(cat "$dir/agent")
    slug=$(sed -n 's/^tuicr-session: //p' "$dir/stderr" | tail -n 1)
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

    herdr agent prompt "$agent" "$text" >/dev/null || exit 1
    jq --argjson new "$new" '. + ($new | map({(.id): .content}) | add)' "$sent" \
      >"$sent.tmp" && mv "$sent.tmp" "$sent"
    ;;

  *)
    echo "usage: tuicr.sh branch | mr | send" >&2
    exit 2
    ;;
esac
