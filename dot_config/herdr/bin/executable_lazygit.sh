#!/bin/sh
# The alt+g tab has one pane that runs `exec lazygit`. The tab closes when
# lazygit quits. A second alt+g in the same directory must focus that tab, not
# open another one.
#
# Panes have no marker for the alt+g lazygit. The match uses the foreground cwd
# of the pane and a foreground process named lazygit. herdr cannot read back env
# passed at create time, and lazygit sets no terminal title.
#
# POSIX sh, not fish: this is key-bound, and fish spends ~110ms sourcing
# config.fish per process.

cwd=${HERDR_ACTIVE_PANE_CWD:-$PWD}
# A pane ID starts with its workspace ID and a colon. With no colon, there is no
# workspace ID to read.
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

# Each candidate pane costs one process-info call. The cwd filter runs first.
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
