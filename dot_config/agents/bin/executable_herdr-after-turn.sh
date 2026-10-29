#!/usr/bin/env bash
# Usage: herdr-after-turn.sh <pane> [--clear <name>] [action ...], prompt text on stdin
# Runs detached after an agent turn. Finds the adapter of the agent in <pane> with
# bin/agent-lib.sh, and gets the adapter text of each action before it waits. Then waits until the
# agent ends its turn. With --clear, clears the session with the action `clear <name>`: the old
# conversation gets <name> as its title. Then submits the text of each action, then the prompt.
# An action is one argument: the action name, then optionally a space and one adapter argument,
# for example "effort medium" or "rename [AB-17] Add f". An action makes no agent turn. With an
# action, the prompt can be empty.
# Exit codes: 0 ok, 1 error
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$here/agent-lib.sh"

die() { echo "herdr-after-turn: $1" >&2; exit 1; }
usage="usage: herdr-after-turn.sh <pane> [--clear <name>] [action ...]"

pane=${1:-}
[[ -n $pane ]] || die "$usage"
shift
name=
if [[ ${1:-} == --clear ]]; then
  name=${2:-}
  [[ -n $name ]] || die "$usage"
  shift 2
fi
prompt=$(cat)
[[ -n $prompt || $# -gt 0 ]] || die "no prompt text on stdin and no action"
pause=${HERDR_AFTER_TURN_SLEEP:-2}

kind=$(agent_kind "$pane") || exit 1
adapter=$(agent_adapter "$kind") || exit 1
actions=()
[[ -z $name ]] || actions+=("clear $name")
actions+=("$@")
texts=()
for action in "${actions[@]}"; do
  words=("${action%% *}")
  if [[ $action == *' '* ]]; then words+=("${action#* }"); fi
  text=$("$adapter" "${words[@]}" 2>&1) || die "$text"
  texts+=("$text")
done

herdr agent wait "$pane" --until idle --until "done" --timeout 600000 >/dev/null \
  || die "the agent in $pane did not end its turn"
# No --wait: the actions make no working state, so herdr reports agent_prompt_stalled.
for text in "${texts[@]}"; do
  herdr agent prompt "$pane" "$text" >/dev/null || die "$text failed in $pane"
  sleep "$pause"
done
if [[ -n $prompt ]]; then
  herdr agent prompt "$pane" "$prompt" >/dev/null || die "prompt failed in $pane"
fi
echo "herdr-after-turn: $(date '+%F %T') $pane${name:+ cleared,} submitted"
