#!/usr/bin/env bash
# tmux-fingers alt-action handler.
# Text file -> new tmux split running $EDITOR. Everything else -> macOS `open`.
# fingers pipes match on stdin and runs us chdir'd to the source pane's cwd,
# so relative paths resolve naturally.

set -euo pipefail

editor="${EDITOR:-nvim}"

match=$(cat)
[ -z "$match" ] && exit 0

# fingers only expands leading ~ when action is `:open:`; do it ourselves.
case "$match" in
  "~"|"~/"*) match="$HOME${match#\~}" ;;
esac

# Resolve: as-is (pane cwd or absolute), then fall back to $HOME-relative.
# Example: pane cwd is ~/.config/tmux, text says ".config/tmux/foo" -> try $HOME/.config/tmux/foo.
path=""
if [ -f "$match" ]; then
  path="$match"
elif [ -f "$HOME/$match" ]; then
  path="$HOME/$match"
fi

if [ -n "$path" ]; then
  enc=$(file -b --mime-encoding -- "$path" 2>/dev/null || echo binary)
  if [ "$enc" != "binary" ]; then
    # tmux runs the command via `sh -c`, so build a properly quoted string.
    # $editor may contain args (e.g. "code -w"); only the path needs quoting.
    printf -v quoted '%q' "$path"
    exec tmux split-window -c "$PWD" "$editor $quoted"
  fi
  exec open "$path"
fi

exec open "$match"
