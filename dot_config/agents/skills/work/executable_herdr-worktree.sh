#!/usr/bin/env bash
# Usage: herdr-worktree.sh <branch> [--repo PATH]
# Opens a local git branch as a Herdr worktree workspace. If the branch has a worktree, the script
# uses it. --repo: the repo (default: the current directory).
# Emits one JSON line: path, workspace_id, root_pane_id. root_pane_id is the idle shell pane of a
# workspace that this script opened. It is empty if the workspace was open.
# Exit codes: 0 ok, 1 usage/other, 2 branch not found, 4 not in Herdr / missing dep

set -euo pipefail

E_NOTFOUND=2
E_DEP=4

die() { echo "herdr-worktree: $1" >&2; exit "${2:-1}"; }

branch="" repo="$PWD"
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo needs a path"; repo="$2"; shift 2 ;;
    -*)     die "unknown option: $1" ;;
    *)      [[ -z "$branch" ]] || die "unexpected argument: $1"; branch="$1"; shift ;;
  esac
done
[[ -n "$branch" ]] || die "usage: herdr-worktree.sh <branch> [--repo PATH]"

[[ "${HERDR_ENV-}" == 1 ]] || die "not in a Herdr pane (HERDR_ENV is not 1)" "$E_DEP"
command -v jq >/dev/null || die "jq not installed" "$E_DEP"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $repo"
# With no local branch, `herdr worktree create` makes a new branch from HEAD.
git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" \
  || die "no local branch '$branch' in $repo" "$E_NOTFOUND"

existing=$(herdr worktree list --cwd "$repo" | jq -c --arg b "$branch" \
  '[.result.worktrees[] | select(.branch == $b and (.is_prunable | not))][0] // empty')

root_pane=""
if [[ -n "$existing" ]]; then
  path=$(jq -r '.path' <<<"$existing")
  workspace=$(jq -r '.open_workspace_id // empty' <<<"$existing")
  if [[ -z "$workspace" ]]; then
    opened=$(herdr worktree open --cwd "$repo" --path "$path" --no-focus)
    workspace=$(jq -r '.result.workspace.workspace_id' <<<"$opened")
    root_pane=$(jq -r '.result.root_pane.pane_id' <<<"$opened")
  fi
else
  made=$(herdr worktree create --cwd "$repo" --branch "$branch" --no-focus)
  path=$(jq -r '.result.worktree.path' <<<"$made")
  workspace=$(jq -r '.result.workspace.workspace_id' <<<"$made")
  root_pane=$(jq -r '.result.root_pane.pane_id' <<<"$made")
fi

jq -nc --arg path "$path" --arg workspace "$workspace" --arg root "$root_pane" \
  '{path:$path, workspace_id:$workspace, root_pane_id:$root}'
