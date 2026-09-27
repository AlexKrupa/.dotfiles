#!/usr/bin/env bash
# Usage: work-next.sh <pane> <old-branch>, prompt text on stdin
# Runs detached after a /work turn in a linked worktree. Waits until the Claude agent in <pane>
# ends its turn, clears the session with /clear <old-branch>, then submits the prompt. /clear
# gives the old conversation the old branch name in the /resume list.
# Exit codes: 0 ok, 1 error
set -euo pipefail

die() { echo "work-next: $1" >&2; exit 1; }

pane=${1:-}
old=${2:-}
[[ -n $pane && -n $old ]] || die "usage: work-next.sh <pane> <old-branch>"
prompt=$(cat)
[[ -n $prompt ]] || die "no prompt text on stdin"

herdr agent wait "$pane" --until idle --until "done" --timeout 600000 >/dev/null \
  || die "the agent in $pane did not end its turn"
# No --wait: /clear makes no working state, so herdr reports agent_prompt_stalled.
herdr agent prompt "$pane" "/clear $old" >/dev/null || die "/clear failed in $pane"
sleep 2
herdr agent prompt "$pane" "$prompt" >/dev/null || die "prompt failed in $pane"
echo "work-next: $(date '+%F %T') $pane cleared, prompt submitted"
