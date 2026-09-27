#!/usr/bin/env bash
# herdr nvim-sidebar-size-fix. Corrects a herdr-nvim sidebar whose nvim keeps the pane's
# start size.
#
# herdr starts a plugin pane at the full tab size, then shrinks it to the split. nvim 0.10+
# turns on in-band resize reports (mode 2048) and then ignores SIGWINCH. herdr sends no
# report when a program turns the mode on. If nvim reads its size before the shrink, it
# keeps the full width until the next real resize, and its lines go into the next row.
# A resize by 0.01 and back is that real resize.
#
# Usage: fix.sh on-created    pane.created hook: watch the pane if it is the nvim sidebar
#        fix.sh watch <pane>  compare nvim's size with its pty for a few seconds, and
#                             resize the pane if they differ
#
# Env overrides, for tests:
#   NSSF_TRIES     polls before the watch stops (default 25)
#   NSSF_INTERVAL  seconds between polls (default 0.2)

set -u

tries=${NSSF_TRIES:-25}
interval=${NSSF_INTERVAL:-0.2}

on_created() {
  local pane
  pane=$(jq -r 'select(.data.pane.label == "nvim sidebar") | .data.pane.pane_id' \
    <<<"${HERDR_PLUGIN_EVENT_JSON:-}") || return 0
  [ -n "$pane" ] || return 0
  # nvim attaches up to 2 s after the pane opens, so the hook does not wait for it.
  nohup "$0" watch "$pane" >/dev/null 2>&1 &
}

# Prints "<socket> <pid>" of the pane's `nvim --remote-ui` client, or nothing.
client() {
  herdr pane process-info --pane "$1" | jq -r '
    .result.process_info.foreground_processes[]?
    | select(.argv | index("--remote-ui"))
    | "\(.argv[(.argv | index("--server")) + 1]) \(.pid)"'
}

watch() {
  local pane=$1 mismatches=0 socket pid tty ui pty
  for (( i = 0; i < tries; i++ )); do
    sleep "$interval"
    read -r socket pid <<<"$(client "$pane")"
    [ -n "$pid" ] || continue
    # "<rows> <cols>", the same order as `stty size`.
    ui=$(nvim --server "$socket" --remote-expr \
      'join(map(nvim_list_uis()[:0], {_, u -> u.height .. " " .. u.width}))' 2>/dev/null)
    tty=$(ps -o tty= -p "$pid" | tr -d ' ')
    pty=$(stty -f "/dev/$tty" size 2>/dev/null)
    [ -n "$ui" ] && [ -n "$pty" ] || continue
    if [ "$ui" = "$pty" ]; then
      mismatches=0
      continue
    fi
    # One mismatch can be a normal resize that nvim has not read yet.
    (( ++mismatches < 2 )) && continue
    # The sidebar is on the right (the herdr-nvim default), so `left` moves its one border.
    herdr pane resize --pane "$pane" --direction left --amount 0.01 >/dev/null
    herdr pane resize --pane "$pane" --direction right --amount 0.01 >/dev/null
    return 0
  done
}

case ${1:-} in
  on-created) on_created ;;
  watch)      watch "${2:?pane id}" ;;
  *) printf 'usage: %s on-created|watch <pane>\n' "${0##*/}" >&2; exit 2 ;;
esac
