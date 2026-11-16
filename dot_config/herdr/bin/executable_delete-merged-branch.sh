#!/bin/sh
# Deletes a branch if the default branch of origin has its changes, and prints one line about the
# result. A squash or rebase merge makes new commits, so ancestry alone misses it. Patch IDs find
# it. If the merge resolved conflicts, the diffs differ and the branch stays.
#
# For a branch that git-spice tracks, git-spice deletes it, so the branches above it get its
# parent as their new base. They are not rebased: they can be checked out in other worktrees.
#
# Usage: delete-merged-branch.sh [--force] <repo> <branch>
#   --force  also delete a branch that is not merged, if no branch is above it

force=
[ "$1" = --force ] && { force=1; shift; }
repo=$1 branch=$2
g() { git -C "$repo" "$@"; }

merged() {
  g merge-base --is-ancestor "$branch" "$trunk" && return
  cherry=$(g cherry "$trunk" "$branch")
  if [ -n "$cherry" ] && ! printf '%s\n' "$cherry" | grep -q '^+'; then return; fi
  base=$(g merge-base "$trunk" "$branch") || return
  squash=$(g commit-tree "$branch^{tree}" -p "$base" -m squash) || return
  ! g cherry "$trunk" "$squash" | grep -q '^+'
}

g fetch --quiet --prune origin 2>/dev/null
trunk=$(g rev-parse --abbrev-ref origin/HEAD 2>/dev/null) || {
  echo "Branch $branch kept: origin/HEAD is not set"
  exit
}

# Empty if git-spice does not track the branch
up_count=
if g show-ref --verify --quiet refs/spice/data; then
  up_count=$(git-spice -C "$repo" log short --all --json 2>/dev/null |
    jq -rs --arg b "$branch" '.[] | select(.name == $b) | .ups // [] | length')
fi

sha=$(g rev-parse --short "$branch")
if merged; then
  result="Branch $branch deleted: merged into $trunk"
elif [ -n "$force" ] && [ "${up_count:-0}" -eq 0 ]; then
  result="Branch $branch deleted: not merged, was $sha"
elif [ -n "$force" ]; then
  echo "Branch $branch kept: not merged, $up_count branches above it"
  exit
else
  echo "Branch $branch kept: not merged into $trunk"
  exit
fi

if [ -n "$up_count" ]; then
  err=$(git-spice -C "$repo" branch delete --no-prompt --force --restack=none "$branch" 2>&1)
else
  err=$(g branch -D "$branch" 2>&1)
fi || {
  echo "Branch $branch not deleted: $err"
  exit
}
if [ "${up_count:-0}" -gt 0 ]; then
  result="$result, $up_count branches above it need a restack"
fi
echo "$result"
