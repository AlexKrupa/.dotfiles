#!/usr/bin/env bash
# Usage: board-pane.sh --repo PATH [-- BOARD_FLAGS...]
# Opens a pane with `watchd board --repo PATH BOARD_FLAGS...` to the right of the current
# multiplexer pane. If the workspace of the current pane has a pane with the label "watchd board",
# the script does nothing.
# Exit codes: 0 ok, 1 error with the multiplexer stderr text
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

mux=$(cd "$(dirname "$0")/../../bin" && pwd)/mux.sh
pane=$("$mux" pane-current) || exit 1
if "$mux" pane-labeled "$pane" "$label"; then exit 0; fi

board=$("$mux" pane-split "$pane" "$repo" 2>&1) || die "$board"
command=$(printf '%q ' watchd board --repo "$repo" "$@")
"$mux" pane-run "$board" "${command% }" || exit 1
"$mux" pane-rename "$board" "$label" || exit 1
