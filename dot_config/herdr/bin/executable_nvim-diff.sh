#!/bin/sh

tab=$HERDR_ACTIVE_TAB_ID
[ -n "$tab" ] || exit 0
key=$(printf '%s' "$tab" | tr : _)

# Same paths as herdr-nvim daemon.rs and state.rs.
if [ -n "$XDG_RUNTIME_DIR" ]; then
  sock=$XDG_RUNTIME_DIR/herdr-nvim/$key.sock
else
  sock=${TMPDIR:-/tmp}/herdr-nvim/$key.sock
fi
state=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-nvim/$key.json

# The socket outlives a closed sidebar.
grep -q '"phase":"Open"' "$state" 2>/dev/null ||
  herdr plugin action invoke toggle --plugin chmarax.herdr-nvim

i=0
while [ ! -S "$sock" ] && [ $i -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -S "$sock" ] || exit 1

cd "${HERDR_ACTIVE_PANE_CWD:-.}" || exit 1
base=$(git rev-parse --verify -q main || git rev-parse --verify -q master) || exit 1
rev=$(git merge-base "$base" HEAD) || exit 1

# --remote-send fails in insert mode.
nvim --headless --server "$sock" --remote-expr "execute('DiffviewClose | DiffviewOpen $rev')"
