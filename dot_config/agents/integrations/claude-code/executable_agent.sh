#!/usr/bin/env bash
# Usage: agent.sh kind
#        agent.sh clear <title>
#        agent.sh effort <level>
#        agent.sh rename <title>
#        agent.sh start-args <title> [--model <model>] [--effort <level>]
# Prints the Claude Code text of one agent action. Writes nothing.
# - kind: the herdr agent kind.
# - clear, effort, rename: the slash command, one line.
# - start-args: the claude arguments, one on each line: --name, <title>, then the given flags and
#   values in the given order.
# Exit codes: 0 ok, 2 usage error, 3 the agent has no such action.
set -euo pipefail

usage() {
  echo "claude-code: usage: agent.sh kind | clear <title> | effort <level> | rename <title> |" \
    "start-args <title> [--model <model>] [--effort <level>]" >&2
  exit 2
}

(($#)) || usage
action=$1
shift
case $action in
  kind)
    (($# == 0)) || usage
    echo claude
    ;;
  clear | effort | rename)
    [[ $# -eq 1 && -n $1 ]] || usage
    printf '/%s %s\n' "$action" "$1"
    ;;
  start-args)
    [[ $# -ge 1 && -n $1 ]] || usage
    args=(--name "$1")
    shift
    while (($#)); do
      [[ ($1 == --model || $1 == --effort) && $# -ge 2 && -n $2 ]] || usage
      args+=("$1" "$2")
      shift 2
    done
    printf '%s\n' "${args[@]}"
    ;;
  *)
    echo "claude-code: no $action action" >&2
    exit 3
    ;;
esac
