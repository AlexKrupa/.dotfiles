#!/usr/bin/env bash
# Usage: worktree.sh <branch> [--repo PATH]
# Opens a local git branch as a worktree workspace of the multiplexer. If the branch has a
# worktree, the script uses it. --repo: the repo (default: the current directory).
# Emits one JSON line: path, workspace_id, root_pane_id. root_pane_id is the idle shell pane of a
# workspace that this script opened. It is empty if the workspace was open.
# Exit codes: 0 ok, 1 usage/other, 2 branch not found, 4 not in a multiplexer / missing dep

set -euo pipefail

E_NOTFOUND=2
E_DEP=4

here=$(cd "$(dirname "$0")" && pwd -P)
mux=$here/../../bin/mux.sh

die() { echo "worktree: $1" >&2; exit "${2:-1}"; }

branch="" repo="$PWD"
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo needs a path"; repo="$2"; shift 2 ;;
    -*)     die "unknown option: $1" ;;
    *)      [[ -z "$branch" ]] || die "unexpected argument: $1"; branch="$1"; shift ;;
  esac
done
[[ -n "$branch" ]] || die "usage: worktree.sh <branch> [--repo PATH]"

command -v jq >/dev/null || die "jq not installed" "$E_DEP"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $repo"
git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" \
  || die "no local branch '$branch' in $repo" "$E_NOTFOUND"

worktrees=$("$mux" worktree-list "$repo") || exit $?
existing=$(awk -F'\t' -v b="$branch" '$1 == b { print; exit }' <<<"$worktrees")

root_pane=""
if [[ -n "$existing" ]]; then
  IFS=$'\t' read -r _ path workspace <<<"$existing"
  if [[ -z "$workspace" ]]; then
    opened=$("$mux" worktree-open "$repo" "$path") || exit 1
    IFS=$'\t' read -r workspace root_pane <<<"$opened"
  fi
else
  made=$("$mux" worktree-create "$repo" "$branch") || exit 1
  IFS=$'\t' read -r path workspace root_pane <<<"$made"
fi

jq -nc --arg path "$path" --arg workspace "$workspace" --arg root "$root_pane" \
  '{path:$path, workspace_id:$workspace, root_pane_id:$root}'
