#!/bin/bash
# Usage: herdr.sh <operation> [arguments]
# The herdr backend of bin/mux.sh, with the same operations, output and exit codes.
# Exit codes: 0 ok, 1 error (stderr has the herdr error message), 5 the pane is busy, 6 the agent is
# not ready
set -uo pipefail

die() { echo "mux/herdr: $1" >&2; exit 1; }

# herdr prints an error as JSON on stderr: {"error": {"code", "message"}}. The callers get only the
# message and the exit code of the operation.
# No temp file: the nono policy of start-claude passes no PATH, so only bash builtins and herdr work.
run() {
  local errors code message
  { errors=$(herdr "$@" 2>&1 >&3 3>&-); } 3>&1 && return 0
  code=$(jq -r '.error.code? // empty' <<<"$errors" 2>/dev/null)
  message=$(jq -r '.error.message? // empty' <<<"$errors" 2>/dev/null)
  [[ -n $message ]] || message=${code:-$errors}
  echo "$message" >&2
  case $code in
    agent_pane_busy) exit 5 ;;
    agent_not_ready) exit 6 ;;
    *) exit 1 ;;
  esac
}

query() {
  local filter=$1 json
  shift
  json=$(run "$@") || exit $?
  jq -r "$filter" <<<"$json" || exit 1
}

call() { run "$@" >/dev/null; }

tsv='map(. // "" | tostring | gsub("[\t\r\n]"; " ")) | join("\t")'

operation=${1:-}
shift
case $operation in
  pane-current) query '.result.pane.pane_id' pane current --current ;;
  pane-cwd) query '.result.pane | .foreground_cwd // .cwd' pane get "$1" ;;
  pane-split)
    focus=()
    if [[ ${3:-} == --focus ]]; then focus=(--focus); fi
    query '.result.pane.pane_id' \
      pane split --pane "$1" --direction right --cwd "$2" ${focus[@]+"${focus[@]}"}
    ;;
  pane-run) call pane run "$1" "$2" ;;
  pane-rename) call pane rename "$1" "$2" ;;
  pane-read) run agent read "$1" --source recent --lines "$2" ;;
  pane-zoom)
    case $2 in
      on | off) call pane zoom "$1" "--$2" ;;
      *) die "pane-zoom needs on or off, not '$2'" ;;
    esac
    ;;
  pane-labeled)
    workspace=$(query '.result.pane.workspace_id' pane current --pane "$1") || exit $?
    panes=$(run pane list --workspace "$workspace") || exit $?
    # jq -e exits 4 or 5 for bad input, and 4 means no multiplexer.
    jq -e --arg label "$2" 'any(.result.panes[]; .label == $label)' <<<"$panes" >/dev/null || exit 1
    ;;
  workspace-first-pane) query '.result.panes[0].pane_id' pane list --workspace "$1" ;;
  workspace-label) query '.result.workspace.label' workspace get "$1" ;;
  workspace-rename) call workspace rename "$1" "$2" ;;
  workspace-close) call workspace close "$1" ;;
  worktree-list)
    query ".result.worktrees[] | select(.is_prunable | not)
      | [.branch, .path, .open_workspace_id] | $tsv" worktree list --cwd "$1"
    ;;
  worktree-open)
    query "[.result.workspace.workspace_id, .result.root_pane.pane_id] | $tsv" \
      worktree open --cwd "$1" --path "$2" --no-focus
    ;;
  worktree-create)
    fields="[.result.worktree.path, .result.workspace.workspace_id, .result.root_pane.pane_id]"
    query "$fields | $tsv" worktree create --cwd "$1" --branch "$2" --no-focus
    ;;
  agent-kind) query '.result.agent.agent // empty' agent get "$1" ;;
  agent-session) query '.result.agent.agent_session.value // empty' agent get "$1" ;;
  agent-start)
    pane=$1 name=$2 kind=$3
    shift 3
    [[ ${1:-} == -- ]] || die "usage: agent-start <pane> <name> <kind> -- <agent arguments>"
    shift
    call agent start "$name" --kind "$kind" --pane "$pane" -- "$@"
    ;;
  agent-wait) call agent wait "$1" --until idle --until "done" --timeout 600000 ;;
  # No --wait: a prompt that makes no working state gives agent_prompt_stalled.
  agent-prompt) call agent prompt "$1" "$2" ;;
  agent-list)
    query ".result.agents[] | [.pane_id, .agent_status, .cwd, .terminal_title_stripped] | $tsv" \
      agent list
    ;;
  notify) call notification show "$1" --body "$2" --sound request ;;
  *) die "unknown operation: $operation" ;;
esac
