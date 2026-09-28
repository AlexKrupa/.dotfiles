#!/bin/sh
# Usage: nvim-diff.sh diffview|codediff

tool=$1
case $tool in
  diffview | codediff) ;;
  *)
    echo "usage: nvim-diff.sh diffview|codediff" >&2
    exit 2
    ;;
esac

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

# --remote-send fails in insert mode.
if [ "$tool" = diffview ]; then
  rev=$(git merge-base "$base" HEAD) || exit 1
  # The Diffview commands take no `|`. DiffviewClose exists only after diffview loads.
  nvim --headless --server "$sock" --remote-expr "execute(['silent! DiffviewClose', 'DiffviewOpen $rev'])" >/dev/null
  exit
fi

# Focus an open CodeDiff tab, else diff the merge-base against the working tree.
lua='(function(base)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "codediff-explorer" then
        vim.api.nvim_set_current_tabpage(tab)
        return 0
      end
    end
  end
  vim.cmd("CodeDiff " .. base .. "...")
  return 0
end)(_A)'

nvim --headless --server "$sock" --remote-expr "luaeval('$lua', '$base')" >/dev/null
