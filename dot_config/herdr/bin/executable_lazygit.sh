#!/bin/sh
# Focus the lazygit tab for this directory, or open one.
#
# The alt+g tab is temporary: it holds one pane running `exec lazygit`, so it
# goes when lazygit quits. A second alt+g in the same directory must land on
# that tab instead of stacking another one.
#
# Panes carry no marker for "this is the alt+g lazygit", so the match is the
# pane's foreground cwd plus a foreground process named lazygit. Env passed at
# create time is not readable back, and lazygit sets no terminal title.
#
# POSIX sh, not fish: this is key-bound, and fish spends ~110ms sourcing
# config.fish per process.

cwd=${HERDR_ACTIVE_PANE_CWD:-$PWD}
# A pane ID is workspace-qualified, so the workspace is its prefix. No colon
# means no ID to read it from.
ws=${HERDR_ACTIVE_PANE_ID%%:*}
[ "$ws" = "$HERDR_ACTIVE_PANE_ID" ] && ws=

# --workspace keeps the new tab in the workspace the search covered. Without it
# the server picks whichever workspace the UI has focused.
open() {
  [ -n "$ws" ] && set -- --workspace "$ws"
  exec herdr tab create "$@" --focus --cwd "$cwd" --env "PATH=$PATH" \
    --env "HERDR_PANE_CMD=exec lazygit"
}

command -v jq >/dev/null || open
[ -n "$ws" ] || open

# One process-info call per candidate pane, so cwd narrows the list first.
panes=$(herdr pane list --workspace "$ws")
for pane in $(printf '%s' "$panes" | jq -r --arg cwd "$cwd" '.result.panes[]
  | select((.foreground_cwd // .cwd) == $cwd) | .pane_id'); do
  herdr pane process-info --pane "$pane" |
    jq -e '[.result.process_info.foreground_processes[].name]
           | index("lazygit")' >/dev/null || continue
  tab=$(printf '%s' "$panes" |
    jq -r --arg p "$pane" '.result.panes[] | select(.pane_id == $p) | .tab_id')
  [ -n "$tab" ] && exec herdr tab focus "$tab" >/dev/null
done

open
