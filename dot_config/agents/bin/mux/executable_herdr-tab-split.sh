#!/bin/bash
# Usage: herdr-tab-split.sh <pane> <cwd> [--focus]
# The tab-split operation of mux/herdr.sh. Opens a new pane on the right edge of the tab of <pane>,
# at the full height of the tab, and prints its id. The other panes keep their ids, layout, ratios
# and processes. Focus goes to the new pane with --focus, else back to the pane that had it.
#
# herdr 0.9.5 can split only one pane. A pane move inside the same tab changes nothing, and
# layout.apply makes new panes, which stops their processes. A move to another tab keeps the pane
# and its process. So all panes but one go to a parking tab, that pane splits, and the other panes
# move back. tab-split.jq computes the moves.
#
# A failed step leaves panes in the parking tab, and the user moves them back. If failures become
# common: write each move to a state file before it runs, and let the next run move the panes back
# from that file.
set -uo pipefail

die() { echo "mux/herdr: $1" >&2; exit 1; }

# Prints the output of herdr. On an error, prints the herdr error message and returns 1.
run() {
  local errors message
  { errors=$(herdr "$@" 2>&1 >&3 3>&-); } 3>&1 && return 0
  message=$(jq -r '.error.message? // empty' <<<"$errors" 2>/dev/null)
  printf '%s\n' "${message:-$errors}"
  return 1
}

# The CLI has no layout tree and no focus without a tab switch, so these go to the socket.
rpc() {
  local response
  response=$(printf '{"id":"rpc","method":"%s","params":%s}\n' "$1" "$2" |
    nc -U -w 3 "$HERDR_SOCKET_PATH") || die "$1: no answer from $HERDR_SOCKET_PATH"
  jq -e '.result' <<<"$response" >/dev/null || die "$1: $response"
  printf '%s\n' "$response"
}

# After the park, the tab is not as the user left it.
broken() {
  run notification show "tab-split failed" \
    --body "$1. The other panes are in the tab-split tab." --sound request >/dev/null
  die "$1"
}

pane=$1 cwd=$2 focus=${3:-}

out=$(run pane get "$pane") || die "$out"
tab=$(jq -r '.result.pane.tab_id' <<<"$out") || exit 1

lock=${TMPDIR:-/tmp}/tab-split/${tab//:/_}.lock
mkdir -p "${lock%/*}" || exit 1
if ! mkdir "$lock" 2>/dev/null; then
  pid=$(cat "$lock/pid" 2>/dev/null)
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then die "tab-split already runs in this tab"; fi
  rm -rf "$lock"
  mkdir "$lock" 2>/dev/null || die "tab-split already runs in this tab"
fi
trap 'rm -rf "$lock"' EXIT
echo $$ >"$lock/pid"

layout=$(rpc layout.export "$(jq -nc --arg tab "$tab" '{tab_id: $tab}')") || exit 1
if jq -e '.result.layout.zoomed' <<<"$layout" >/dev/null; then
  out=$(run pane zoom "$pane" --off) || die "$out"
fi
focused=$(jq -r '.result.layout.focused_pane_id' <<<"$layout") || exit 1
plan=$(jq -c -L "${BASH_SOURCE[0]%/*}" 'include "tab-split"; tab_split_plan' <<<"$layout") ||
  exit 1

parking=
while read -r id; do
  if [[ -z $parking ]]; then
    out=$(run pane move "$id" --new-tab --label tab-split --no-focus) || broken "$out"
    parking=$(jq -r '.result.move_result.pane.tab_id' <<<"$out")
  else
    out=$(run pane move "$id" --tab "$parking" --split right --no-focus) || broken "$out"
  fi
done < <(jq -r '.parked[]' <<<"$plan")

read -r anchor ratio < <(jq -r '"\(.anchor) \(.ratio)"' <<<"$plan")
out=$(run pane split --pane "$anchor" --direction right --ratio "$ratio" --cwd "$cwd" --no-focus) ||
  broken "$out"
new=$(jq -r '.result.pane.pane_id' <<<"$out")

while IFS=$'\t' read -r id target direction ratio; do
  out=$(run pane move "$id" --tab "$tab" --split "$direction" --target-pane "$target" \
    --ratio "$ratio" --no-focus) || broken "$out"
done < <(jq -r '.moves[] | [.pane, .target, .direction, .ratio] | @tsv' <<<"$plan")

if [[ $focus == --focus ]]; then focused=$new; fi
rpc pane.focus "$(jq -nc --arg pane "$focused" '{pane_id: $pane}')" >/dev/null
printf '%s\n' "$new"
