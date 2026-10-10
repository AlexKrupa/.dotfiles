#!/usr/bin/env bash
# Usage: herdr-after-turn.sh <pane> [--clear <name>] [command ...], prompt text on stdin
# Runs detached after a Claude turn. Waits until the Claude agent in <pane> ends its turn. With
# --clear, clears the session with /clear <name>: the old conversation gets <name> as its title in
# the /resume list. Then submits each command, then the prompt. A command is a slash command that
# makes no agent turn, for example "/effort medium". With a command, the prompt can be empty.
# Exit codes: 0 ok, 1 error
set -euo pipefail

die() { echo "herdr-after-turn: $1" >&2; exit 1; }
usage="usage: herdr-after-turn.sh <pane> [--clear <name>] [command ...]"

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
[[ -n $prompt || $# -gt 0 ]] || die "no prompt text on stdin and no command"
pause=${HERDR_AFTER_TURN_SLEEP:-2}

herdr agent wait "$pane" --until idle --until "done" --timeout 600000 >/dev/null \
  || die "the agent in $pane did not end its turn"
# No --wait: /clear and the commands make no working state, so herdr reports
# agent_prompt_stalled.
if [[ -n $name ]]; then
  herdr agent prompt "$pane" "/clear $name" >/dev/null || die "/clear failed in $pane"
  sleep "$pause"
fi
for command in "$@"; do
  herdr agent prompt "$pane" "$command" >/dev/null || die "$command failed in $pane"
  sleep "$pause"
done
[[ -z $prompt ]] || herdr agent prompt "$pane" "$prompt" >/dev/null || die "prompt failed in $pane"
echo "herdr-after-turn: $(date '+%F %T') $pane${name:+ cleared,} submitted"
