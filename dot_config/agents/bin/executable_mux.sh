#!/bin/bash
# Usage: mux.sh <operation> [arguments]
# Runs the operation in the multiplexer of this pane: bin/mux/herdr.sh if HERDR_ENV is 1, else
# bin/mux/rex.sh if REX_SESSION is set. herdr comes first, because a herdr pane inside a Rex
# terminal belongs to herdr. A workspace is a herdr workspace or a Rex session.
# A caller with no pane, for example the watch daemon, sets MUX_REPO to the main checkout of a repo.
# Then the multiplexer with a pane in that folder runs the operation, herdr first. That pane is the
# current pane.
# Writes nothing, except worktree-create: a git worktree, and a branch if it is new.
# Output: one value on each line, or TSV lines. Tab, CR and LF in a TSV field become a space.
# - pane-current: the pane id of this process
# - pane-cwd <pane>: the cwd of the foreground program, else of the pane
# - pane-split <pane> <cwd> [--focus]: the id of a new pane to the right
# - pane-run <pane> <command>
# - pane-rename <pane> <label>
# - repo-pane <folder>: the id of a pane in <folder> or below it. Exit 1 if there is none.
# - pane-read <pane> <lines>: the last <lines> lines of the screen and scrollback, as text
# - pane-zoom <pane> on|off
# - pane-labeled <pane> <label>: exit 0 if the workspace of <pane> has a pane with <label>, else 1
# - workspace-first-pane <workspace>: the first pane id
# - workspace-label <workspace>: the label
# - workspace-rename <workspace> <label>
# - workspace-close <workspace>
# - worktree-list <repo>: TSV branch, path, workspace. The workspace is empty for a worktree that is
#   not open. No prunable worktrees.
# - worktree-open <repo> <path>: TSV workspace, root pane
# - worktree-create <repo> <branch>: TSV path, workspace, root pane
# - agent-kind <pane>: the agent kind, for example claude. Empty if the pane has no agent.
# - agent-session <pane>: the agent session id
# - agent-start <pane> <name> <kind> -- <agent arguments>: exit 5 if the pane is busy, 6 if the
#   agent is not ready
# - agent-wait <pane>: exit 0 when the agent is idle or done, 1 after 600 s
# - agent-prompt <pane> <text>: submits <text>
# - agent-list: TSV pane, status, cwd, title
# - notify <title> <body>
# Exit codes: 0 ok, 1 error (stderr has the backend error text), 4 not in a multiplexer, 5 and 6
# as the operation says
# No dirname: a caller can run this script with no PATH.
here=${BASH_SOURCE[0]%/*}
if [[ ${HERDR_ENV:-} == 1 ]]; then
  exec "$here/mux/herdr.sh" "$@"
elif [[ -n ${REX_SESSION:-} ]]; then
  exec "$here/mux/rex.sh" "$@"
elif [[ -n ${MUX_REPO:-} ]]; then
  for backend in herdr rex; do
    if MUX_PANE=$("$here/mux/$backend.sh" repo-pane "$MUX_REPO" 2>/dev/null); then
      export MUX_PANE
      exec "$here/mux/$backend.sh" "$@"
    fi
  done
  echo "mux: no herdr or Rex pane in $MUX_REPO" >&2
  exit 4
fi
echo "mux: not in herdr or Rex" >&2
exit 4
