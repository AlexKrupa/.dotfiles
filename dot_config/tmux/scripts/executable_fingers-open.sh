#!/usr/bin/env bash
# tmux-fingers alt-action handler.
# Text file -> new tmux split running $EDITOR. Everything else -> macOS `open`.
# fingers pipes match on stdin and runs us chdir'd to the source pane's cwd,
# so relative paths resolve naturally.

set -euo pipefail

editor="${EDITOR:-nvim}"

match=$(cat)
[ -z "$match" ] && exit 0

if [ -f "$match" ]; then
  enc=$(file -b --mime-encoding -- "$match" 2>/dev/null || echo binary)
  if [ "$enc" != "binary" ]; then
    # tmux runs the command via `sh -c`, so build a properly quoted string.
    # $editor may contain args (e.g. "code -w"); only the path needs quoting.
    printf -v quoted '%q' "$match"
    exec tmux split-window -c "$PWD" "$editor $quoted"
  fi
fi

exec open "$match"
