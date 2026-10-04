#!/bin/sh
# Remove the active worktree workspace without the sidebar dialog.
#
# The dialog takes all keys until `git worktree remove` has deleted the whole
# checkout, which takes seconds for a large one. This script is key-bound as a
# detached shell command, so the UI stays free. A toast shows the result.
#
# There is no confirmation. git refuses to remove a checkout with changes, and
# the toast then shows the error. `--force` removes it with the changes.
#
# Usage: remove-worktree.sh [--force]

herdr=${HERDR_BIN_PATH:-herdr}
ws=$HERDR_ACTIVE_WORKSPACE_ID
[ -n "$ws" ] || exit 1

label=$("$herdr" workspace get "$ws" | jq -r '.result.workspace.label')

if err=$("$herdr" worktree remove --workspace "$ws" "$@" 2>&1 >/dev/null); then
  "$herdr" notification show "Worktree removed" --body "$label"
else
  "$herdr" notification show "Worktree not removed: $label" \
    --body "$(printf '%s' "$err" | jq -r '.error.message? // .')" --sound request
fi
