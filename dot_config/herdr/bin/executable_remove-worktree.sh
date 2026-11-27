#!/bin/sh
# The sidebar dialog takes all keys until `git worktree remove` deletes the whole
# checkout. For a large checkout, this takes seconds. A key runs this script as
# a detached shell command, and the UI stays free. A toast shows the result.
#
# There is no confirmation. git refuses to remove a checkout with changes, and
# the toast then shows the error. `--force` removes it with the changes. If git
# removes the worktree but not its folder, the script deletes the folder and
# closes the workspace.
#
# After the removal, `delete-merged-branch.sh` deletes the branch if it is merged.
# `--force` also deletes a branch that is not merged.
#
# Usage: remove-worktree.sh [--force]

herdr=${HERDR_BIN_PATH:-herdr}
ws=$HERDR_ACTIVE_WORKSPACE_ID
[ -n "$ws" ] || exit 1

workspace=$("$herdr" workspace get "$ws")
label=$(printf '%s' "$workspace" | jq -r '.result.workspace.label')
repo=$(printf '%s' "$workspace" | jq -r '.result.workspace.worktree.repo_root // empty')
checkout=$(printf '%s' "$workspace" | jq -r '.result.workspace.worktree.checkout_path // empty')
# `git -C ""` runs in the current directory, so an empty path must not reach git
branch=$([ -n "$checkout" ] && git -C "$checkout" symbolic-ref --quiet --short HEAD 2>/dev/null)

# git deletes its record of the worktree before the folder. If the folder delete fails, for example
# because a Gradle daemon writes `.gradle/` again, git exits with an error, but the worktree is gone.
unlisted() {
  [ -n "$repo" ] && [ -d "$checkout" ] || return
  path=$(cd "$checkout" && pwd -P)
  [ "$path" != "$(cd "$repo" && pwd -P)" ] &&
    ! git -C "$repo" worktree list --porcelain | grep -qxF "worktree $path"
}

note=
if err=$("$herdr" worktree remove --workspace "$ws" "$@" 2>&1 >/dev/null); then
  :
elif unlisted; then
  rm -rf "$checkout" 2>/dev/null || note="Folder not deleted: $checkout"
  "$herdr" workspace close "$ws"
else
  "$herdr" notification show "Worktree not removed: $label" \
    --body "$(printf '%s' "$err" | jq -r '.error.message? // .')" --sound request
  exit
fi

body=$label${note:+
$note}
if [ -n "$branch" ]; then
  body="$body
$("$(dirname "$0")/delete-merged-branch.sh" "$@" "$repo" "$branch")"
fi
"$herdr" notification show "Worktree removed" --body "$body"
