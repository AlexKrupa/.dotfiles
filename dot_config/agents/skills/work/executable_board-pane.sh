#!/usr/bin/env bash
# Usage: board-pane.sh --repo PATH [-- BOARD_FLAGS...]
# Opens a pane with `watchd board --repo PATH BOARD_FLAGS...` to the right of the current herdr
# pane. If the workspace of the current pane has a pane with the label "watchd board", the script
# does nothing.
# Exit codes: 0 ok, 1 error with the herdr stderr text
set -euo pipefail

label="watchd board"

die() { echo "board-pane: $1" >&2; exit 1; }

repo=
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo needs a path"; repo=$2; shift 2 ;;
    --) shift; break ;;
    *) die "unexpected argument: $1" ;;
  esac
done
[[ -n $repo ]] || die "--repo needs a path"

# Runs herdr and gives its stderr text as the error.
run() {
  local out err
  err=$(mktemp)
  if out=$(herdr "$@" 2>"$err"); then
    rm -f "$err"
    printf '%s' "$out"
  else
    out=$(cat "$err")
    rm -f "$err"
    die "${out:-herdr $1 $2 failed}"
  fi
}

current=$(run pane current --current)
pane=$(jq -r '.result.pane.pane_id' <<<"$current")
workspace=$(jq -r '.result.pane.workspace_id' <<<"$current")
panes=$(run pane list --workspace "$workspace")
if jq -e --arg label "$label" 'any(.result.panes[]; .label == $label)' <<<"$panes" >/dev/null; then
  exit 0
fi

board=$(run pane split "$pane" --direction right --cwd "$repo" | jq -r '.result.pane.pane_id')
command=$(printf '%q ' watchd board --repo "$repo" "$@")
run pane run "$board" "${command% }" >/dev/null
run pane rename "$board" "$label" >/dev/null
