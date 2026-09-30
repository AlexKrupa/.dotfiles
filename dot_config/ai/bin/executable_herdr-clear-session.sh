#!/usr/bin/env bash
# Usage: herdr-clear-session.sh <pane> <name> [command ...], prompt text on stdin
# Runs detached after a Claude turn. Waits until the Claude agent in <pane> ends its turn, clears
# the session with /clear <name>, submits each command, then submits the prompt. /clear gives the
# old conversation <name> as its title in the /resume list. A command is a slash command that
# makes no agent turn, for example "/effort medium".
# Exit codes: 0 ok, 1 error
set -euo pipefail

die() { echo "herdr-clear-session: $1" >&2; exit 1; }

pane=${1:-}
name=${2:-}
[[ -n $pane && -n $name ]] || die "usage: herdr-clear-session.sh <pane> <name> [command ...]"
shift 2
prompt=$(cat)
[[ -n $prompt ]] || die "no prompt text on stdin"
pause=${HERDR_CLEAR_SLEEP:-2}

herdr agent wait "$pane" --until idle --until "done" --timeout 600000 >/dev/null \
  || die "the agent in $pane did not end its turn"
# No --wait: /clear and the commands make no working state, so herdr reports
# agent_prompt_stalled.
herdr agent prompt "$pane" "/clear $name" >/dev/null || die "/clear failed in $pane"
sleep "$pause"
for command in "$@"; do
  herdr agent prompt "$pane" "$command" >/dev/null || die "$command failed in $pane"
  sleep "$pause"
done
herdr agent prompt "$pane" "$prompt" >/dev/null || die "prompt failed in $pane"
echo "herdr-clear-session: $(date '+%F %T') $pane cleared, prompt submitted"
