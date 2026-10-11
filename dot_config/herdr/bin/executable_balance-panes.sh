#!/bin/sh
# One file because a keybinding runs one command. The built-in split and close
# actions are unset in config.toml: herdr fires nothing after a split, and a
# close has to be read before the pane goes. Both pair a CLI call with an
# equalize here.
#
# POSIX sh, not fish: this is key-bound, and fish spends ~110ms sourcing
# config.fish per process.
#
# This script changes only ratios. Pane areas are equal only when the whole tab
# splits in one direction. A better result needs a restructured tree.

bin=$(dirname "$0")

usage() {
  echo "usage: balance-panes.sh split right|down | close | break |" >&2
  echo "       equalize [right|down [path]]" >&2
  exit 2
}

# The CLI does not expose these calls. layout.apply sets every ratio at once but
# takes a whole tree and can recreate panes, which kills running agents.
#
# The server does not close the connection after it replies. Without -w 3 a bare
# `nc -U` waits for ever and stalls the server.
rpc() {
  [ -S "$HERDR_SOCKET_PATH" ] || return 1
  printf '{"id":"rpc","method":"%s","params":%s}\n' "$1" "$2" |
    nc -U -w 3 "$HERDR_SOCKET_PATH"
}

# The optional second argument is a layout path. It finds the group by its
# position in the tree, not by a pane. The close key needs this because its pane
# is already gone.
#
# Tab and pane come from the keybinding env. The server alternative is
# `herdr pane layout --current`, which returns the pane that the UI has focused.
# With a second client attached, that pane can be in the wrong tab.
equalize() {
  dir=${1:-}
  group=${2:-}
  command -v jq >/dev/null || return 0

  tab=$HERDR_ACTIVE_TAB_ID
  pane=$HERDR_ACTIVE_PANE_ID
  [ -n "$tab" ] || return 0
  [ -n "$pane" ] || [ -n "$group" ] || return 0

  # Compact JSON has no spaces. A space is a safe separator for the two fields.
  rpc layout.export "{\"tab_id\":\"$tab\"}" |
    jq -r -L "$bin" --arg pane "$pane" --arg dir "$dir" --arg group "$group" \
      'include "balance";
       if $group == "" then equalize($pane; $dir)
       else equalize_at($group | fromjson; $dir) end' |
    while read -r path ratio; do
      rpc layout.set_split_ratio \
        "{\"tab_id\":\"$tab\",\"path\":$path,\"ratio\":$ratio}" >/dev/null
    done
}

case ${1:-} in
  split)
    case ${2:-} in right | down) ;; *) usage ;; esac
    # --focus matches the built-in actions. `herdr pane split` does not focus
    # the new pane on its own. The pane in the environment stays in the group
    # that was just split. equalize finds the group from that pane.
    [ -n "$HERDR_ACTIVE_PANE_ID" ] || exit 0
    herdr pane split --pane "$HERDR_ACTIVE_PANE_ID" --direction "$2" --focus \
      >/dev/null || exit 1
    equalize "$2"
    ;;

  close)
    [ -n "$HERDR_ACTIVE_PANE_ID" ] || exit 0
    command -v jq >/dev/null || exec herdr pane close "$HERDR_ACTIVE_PANE_ID"

    # Cleared first so the count below never reads this script's own arguments.
    set --
    if [ -n "$HERDR_ACTIVE_TAB_ID" ]; then
      set -- $(rpc layout.export "{\"tab_id\":\"$HERDR_ACTIVE_TAB_ID\"}" |
        jq -r -L "$bin" --arg pane "$HERDR_ACTIVE_PANE_ID" \
          'include "balance"; close_target($pane)')
    fi

    herdr pane close "$HERDR_ACTIVE_PANE_ID" >/dev/null || exit 1
    [ $# -eq 2 ] || exit 0
    equalize "$1" "$2"
    ;;

  break)
    [ -n "$HERDR_ACTIVE_PANE_ID" ] || exit 0
    herdr pane move "$HERDR_ACTIVE_PANE_ID" --new-tab --focus
    ;;

  equalize)
    case ${2:-} in '' | right | down) ;; *) usage ;; esac
    equalize "${2:-}" "${3:-}"
    ;;

  on-exit)
    # Hooks get no HERDR_ACTIVE_* variables and the pane.exited payload has only
    # pane_id and workspace_id. HERDR_TAB_ID is the only source for the tab. It
    # is the tab of the exited pane, not the focused one. Measured on 0.8.0.
    #
    # The pane is not in the tree now. No group is left to find. `[]` is the
    # root, which equalize_at reads as both axes.
    [ -n "$HERDR_TAB_ID" ] || exit 0
    HERDR_ACTIVE_TAB_ID=$HERDR_TAB_ID
    equalize "" "[]"
    ;;

  *) usage ;;
esac
