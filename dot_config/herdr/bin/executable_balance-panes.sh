#!/bin/sh
# Pane splits, closes and evening out. One file with a subcommand each, because
# a keybinding runs one command and config.toml binds the subcommands directly.
# bin/balance.jq picks the splits and the ratios.
#
#   split right|down     split the active pane, even the group the new pane joins
#   close                close the active pane, even the group it leaves behind
#   break                move the active pane to a new tab
#   equalize [dir [path]] even the whole tab, or one row or column group
#
# The built-in split and close actions are unset in config.toml. herdr fires
# nothing after a split, and a close has to be read before the pane goes, so
# both pair a CLI call with an equalize here.
#
# POSIX sh, not fish: this is key-bound, and fish spends ~110ms sourcing
# config.fish per process.
#
# Pane *areas* are only equal when the whole tab splits one direction; ratios
# alone cannot do better on a mixed tree without restructuring it.

bin=$(dirname "$0")

usage() {
  echo "usage: balance-panes.sh split right|down | close | break |" >&2
  echo "       equalize [right|down [path]]" >&2
  exit 2
}

# One JSON-RPC call to the herdr socket, for calls the CLI does not expose.
# layout.apply would set every ratio at once but takes a whole tree and can
# recreate panes, which would kill running agents. set_split_ratio only changes
# a ratio.
#
# The server does not close the connection after it replies. Without -w 3 a bare
# `nc -U` waits for ever and stalls the server.
rpc() {
  [ -S "$HERDR_SOCKET_PATH" ] || return 1
  printf '{"id":"rpc","method":"%s","params":%s}\n' "$1" "$2" |
    nc -U -w 3 "$HERDR_SOCKET_PATH"
}

# Give every pane in the current tab an equal share, or with `right` or `down`
# only the row or column group the active pane sits in - what the split key
# uses. A layout path as the second argument names the group by its spot in the
# tree instead of by a pane, which is what the close key needs: the pane it
# would name has already gone.
#
# The keybinding env names the pressing pane and its tab, so nothing has to be
# looked up. Asking the server instead would mean `herdr pane layout --current`,
# which answers for whichever pane the UI has focused - the wrong tab as soon as
# a second client is attached.
equalize() {
  dir=${1:-}
  group=${2:-}
  command -v jq >/dev/null || return 0

  tab=$HERDR_ACTIVE_TAB_ID
  pane=$HERDR_ACTIVE_PANE_ID
  [ -n "$tab" ] || return 0
  [ -n "$pane" ] || [ -n "$group" ] || return 0

  # Compact json has no spaces, so a space splits the two fields.
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
    # --focus matches the built-in actions; `herdr pane split` does not focus
    # the new pane on its own. The pane named in the environment stays in the
    # group that was just split, so equalize can read it from there.
    [ -n "$HERDR_ACTIVE_PANE_ID" ] || exit 0
    herdr pane split --pane "$HERDR_ACTIVE_PANE_ID" --direction "$2" --focus \
      >/dev/null || exit 1
    equalize "$2"
    ;;

  close)
    # `(a | b) | c` closing `b` leaves `a | c` at the 2:1 ratio the three
    # columns had, and this puts it back to 1:1. Closing a pane out of
    # `a | (b / c)` collapses a row split into a column with no row group left,
    # so nothing moves.
    [ -n "$HERDR_ACTIVE_PANE_ID" ] || exit 0
    command -v jq >/dev/null || exec herdr pane close "$HERDR_ACTIVE_PANE_ID"

    # `<direction> <path>`, or nothing when the pane is the whole tab. Cleared
    # first so the count below never reads this script's own arguments.
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
    # Replaces tmux `break-pane`.
    [ -n "$HERDR_ACTIVE_PANE_ID" ] || exit 0
    herdr pane move "$HERDR_ACTIVE_PANE_ID" --new-tab --focus
    ;;

  equalize)
    case ${2:-} in '' | right | down) ;; *) usage ;; esac
    equalize "${2:-}" "${3:-}"
    ;;

  *) usage ;;
esac
