#!/bin/sh
# Fakes herdr, nc, nvim and mux.sh, so it touches no real pane or nvim.
bin=$(cd "$(dirname "$0")/.." && pwd)
script=$bin/nvim-sidebar.sh
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

# Each fake logs its calls to $MOCK_LOG.
# herdr: `pane get` finds the panes in $MOCK_PANES, in tab w1:t1. `tab list` prints the tabs in
# $MOCK_TABS, and fails if MOCK_TABS is unset.
# nvim: the content of the socket file is the state of the server: live, hung or anything else for
# no server. A server start writes live, a quit removes the file.
# mux.sh: pane-cwd prints $tmp/work, tab-split prints w1:p9.
mkdir -p "$tmp/bin" "$tmp/work"
cat >"$tmp/bin/herdr" <<'EOF'
#!/bin/sh
printf 'herdr %s\n' "$*" >>"$MOCK_LOG"
case "$1 $2" in
  "pane get")
    case " ${MOCK_PANES:-} " in
      *" $3 "*) printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:t1"}}}\n' "$3" ;;
      *) echo '{"error":{"code":"pane_not_found"}}' >&2; exit 1 ;;
    esac ;;
  "tab list")
    [ -n "${MOCK_TABS+set}" ] || exit 1
    printf '%s' "$MOCK_TABS" | jq -R -s -c 'split(" ") | map(select(. != "") | {tab_id: .})
      | {result: {tabs: .}}' ;;
esac
EOF
cat >"$tmp/bin/nc" <<'EOF'
#!/bin/sh
printf 'nc %s\n' "$(cat)" >>"$MOCK_LOG"
EOF
cat >"$tmp/bin/nvim" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "--headless --listen" ]; then
  printf 'nvim %s in %s\n' "$*" "$PWD" >>"$MOCK_LOG"
  echo live >"$3"
  exit 0
fi
printf 'nvim %s\n' "$*" >>"$MOCK_LOG"
case $(cat "$2" 2>/dev/null) in
  live) ;;
  hung) exec sleep 10 ;;
  *) echo "E247: Failed to connect to '$2'" >&2; exit 2 ;;
esac
case "$*" in
  *getpid*) echo 999999 ;;
  *--remote-expr*) echo 1 ;;
  *--remote-send*) rm -f "$2" ;;
esac
EOF
cat >"$tmp/bin/mux.sh" <<EOF
#!/bin/sh
printf 'mux.sh %s\n' "\$*" >>"\$MOCK_LOG"
case \$1 in
  pane-cwd) echo "$tmp/work" ;;
  tab-split) echo w1:p9 ;;
esac
EOF
chmod +x "$tmp/bin/"*

export PATH="$tmp/bin:$PATH" TMPDIR=$tmp/t MOCK_LOG=$tmp/calls.log \
  HERDR_SOCKET_PATH=$tmp/herdr.sock HERDR_TAB_ID=w1:t1 HERDR_PANE_ID=w1:p1
state=$TMPDIR/nvim-sidebar
sock=$state/w1_t1.sock

# reset <file=content>...: an empty log and only the given state files.
reset() {
  : >"$MOCK_LOG"
  rm -rf "$state"
  mkdir -p "$state"
  for spec in "$@"; do printf '%s\n' "${spec#*=}" >"$state/${spec%%=*}"; done
}
# The calls without the pings that wait for a new server.
calls() { grep -v -- '--remote-expr 1$' "$MOCK_LOG"; }
files() { (cd "$state" && ls | tr '\n' ' '); }

opened="mux.sh tab-split w1:p1 $tmp/work
mux.sh pane-run w1:p9 exec nvim --remote-ui --server '$sock'
nc {\"id\":\"rpc\",\"method\":\"pane.focus\",\"params\":{\"pane_id\":\"w1:p9\"}}"

reset
"$script" toggle
check "toggle opens: exit 0" 0 $?
check "toggle opens: a server in the cwd of the pane, then the pane, then the focus" \
  "mux.sh pane-cwd w1:p1
nvim --headless --listen $sock in $tmp/work
$opened" "$(calls)"
check "toggle opens: the pane file has the new pane" w1:p9 "$(cat "$state/w1_t1.pane")"

reset w1_t1.sock=live w1_t1.pane=w1:p9
MOCK_PANES=w1:p9 "$script" toggle
check "toggle hides: exit 0" 0 $?
check "toggle hides: closes the pane, no nvim call" "herdr pane get w1:p9
herdr pane close w1:p9" "$(calls)"
check "toggle hides: the server stays, the pane file goes" "w1_t1.sock " "$(files)"

reset w1_t1.sock=live w1_t1.pane=w1:p7
"$script" toggle
check "toggle reuses the server: exit 0" 0 $?
check "toggle reuses the server: no new server" "herdr pane get w1:p7
mux.sh pane-cwd w1:p1
nvim --server $sock --remote-expr 1
$opened" "$(cat "$MOCK_LOG")"

reset w1_t1.sock=dead
"$script" toggle
check "toggle with a stale socket: exit 0" 0 $?
check "toggle with a stale socket: a new server" "mux.sh pane-cwd w1:p1
nvim --headless --listen $sock in $tmp/work
$opened" "$(calls)"
check "toggle with a stale socket: the socket is of the new server" live "$(cat "$sock")"

reset w1_t1.sock=hung
start=$(date +%s)
"$script" toggle
code=$?
seconds=$(($(date +%s) - start))
check "toggle with a hung server: exit 1" 1 "$code"
check "toggle with a hung server: stops after 5 s" yes \
  "$([ "$seconds" -ge 4 ] && [ "$seconds" -le 7 ] && echo yes || echo "no, $seconds s")"
check "toggle with a hung server: a notification, no pane" "mux.sh pane-cwd w1:p1
nvim --server $sock --remote-expr 1
mux.sh notify nvim sidebar nvim does not answer" "$(cat "$MOCK_LOG")"
check "toggle with a hung server: the socket stays" hung "$(cat "$sock")"

reset w1_t1.sock=live
"$script" open /repo/a.txt
check "open with no sidebar: exit 0" 0 $?
check "open with no sidebar: opens the sidebar, then the file" "mux.sh pane-cwd w1:p1
nvim --server $sock --remote-expr 1
$opened
nvim --server $sock --remote /repo/a.txt" "$(cat "$MOCK_LOG")"

reset w1_t1.sock=live w1_t1.pane=w1:p9
MOCK_PANES=w1:p9 "$script" open /repo/a.txt
check "open with the sidebar open: exit 0" 0 $?
check "open with the sidebar open: focuses it and opens the file" "herdr pane get w1:p9
nc {\"id\":\"rpc\",\"method\":\"pane.focus\",\"params\":{\"pane_id\":\"w1:p9\"}}
nvim --server $sock --remote /repo/a.txt" "$(cat "$MOCK_LOG")"
check "open with the sidebar open: the sidebar stays" "w1_t1.pane w1_t1.sock " "$(files)"

stopped() { # stopped <key>: the stop calls for the socket of <key>
  printf "nvim --server %s --remote-expr getpid()\nnvim --server %s --remote-send <C-\\\\><C-n>:qa!<CR>" \
    "$state/$1.sock" "$state/$1.sock"
}

reset w1_t1.sock=live w1_t1.pane=w1:p9 w1_t2.sock=live
HERDR_PLUGIN_EVENT=tab.closed "$script" on-event
check "on-event tab.closed: exit 0" 0 $?
check "on-event tab.closed: stops the nvim of the tab" "$(stopped w1_t1)" "$(cat "$MOCK_LOG")"
check "on-event tab.closed: the nvim of another tab stays" "w1_t2.sock " "$(files)"

reset w1_t1.sock=live w1_t2.sock=live w12_t1.sock=live
HERDR_PLUGIN_EVENT=workspace.closed HERDR_WORKSPACE_ID=w1 HERDR_TAB_ID=w1:t2 "$script" on-event
check "on-event workspace.closed: stops each nvim of the workspace" "$(stopped w1_t1)
$(stopped w1_t2)" "$(cat "$MOCK_LOG")"
check "on-event workspace.closed: the nvim of another workspace stays" "w12_t1.sock " "$(files)"

reset w1_t1.sock=live w1_t1.pane=w1:p9 w1_t2.sock=live w1_t2.pane=w1:p8
MOCK_TABS="w1:t1" MOCK_PANES=w1:p9 "$script" gc
check "gc: exit 0" 0 $?
check "gc: stops the nvim of a closed tab" "$(stopped w1_t2)" \
  "$(grep -- '--server' "$MOCK_LOG")"
check "gc: keeps the nvim and the open pane of a live tab" "w1_t1.pane w1_t1.sock " "$(files)"

reset w1_t1.sock=live w1_t1.pane=w1:p8
MOCK_TABS="w1:t1" "$script" gc
check "gc: removes the pane file of a closed pane" "w1_t1.sock " "$(files)"

reset w1_t1.sock=live w1_t1.pane=w1:p9
"$script" gc
check "gc with no answer from herdr: stops nothing" "w1_t1.pane w1_t1.sock " "$(files)"

exit "$fail"
