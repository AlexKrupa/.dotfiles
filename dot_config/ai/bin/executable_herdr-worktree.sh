#!/usr/bin/env bash
# Opens a local git branch as a Herdr worktree workspace. Reuses the branch's existing worktree
# when there is one. With --move-pane, moves the calling pane into that workspace.
# Emits JSON: path, workspace_id, pane_id, created, moved.
# Exit codes: 0 ok, 1 usage/other, 2 branch not found, 4 not in Herdr / missing dep

set -euo pipefail

E_NOTFOUND=2
E_DEP=4

die() { echo "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'USAGE'
herdr-worktree.sh - open a local branch as a Herdr worktree workspace.

Usage:
  herdr-worktree.sh <branch> [--repo PATH] [--move-pane]

  --repo PATH   repo to use (default: current directory)
  --move-pane   move the calling pane into the worktree workspace

Exit codes: 0 ok · 1 usage/other · 2 branch not found · 4 not in Herdr / missing dep
USAGE
}

branch="" repo="$PWD" move_pane=false
while (($#)); do
  case "$1" in
    --repo)      [[ $# -ge 2 ]] || die "--repo needs a path"; repo="$2"; shift 2 ;;
    --move-pane) move_pane=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die "unknown option: $1" ;;
    *)           [[ -z "$branch" ]] || die "unexpected argument: $1"; branch="$1"; shift ;;
  esac
done
[[ -n "$branch" ]] || { usage >&2; exit 1; }

[[ "${HERDR_ENV-}" == 1 ]] || die "not in a Herdr pane (HERDR_ENV is not 1)" "$E_DEP"
command -v jq >/dev/null || die "jq not installed" "$E_DEP"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $repo"
# Without a local branch, `herdr worktree create` would make a new one from HEAD.
git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" \
  || die "no local branch '$branch' in $repo" "$E_NOTFOUND"

existing=$(herdr worktree list --cwd "$repo" | jq -c --arg b "$branch" \
  '[.result.worktrees[] | select(.branch == $b and (.is_prunable | not))][0] // empty')

created=false root_pane=""
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
  created=true
fi

current=$(herdr pane current --current)
pane=$(jq -r '.result.pane.pane_id' <<<"$current")
moved=false
if [[ "$move_pane" == true && "$(jq -r '.result.pane.workspace_id' <<<"$current")" != "$workspace" ]]; then
  tab=$(herdr workspace get "$workspace" | jq -r '.result.workspace.active_tab_id')
  pane=$(herdr pane move "$pane" --tab "$tab" --split right --focus \
    | jq -r '.result.move_result.pane.pane_id')
  moved=true
  # The root pane is an idle shell this script opened. The moved pane replaces it.
  [[ -z "$root_pane" ]] || herdr pane close "$root_pane" >/dev/null
fi

jq -n \
  --arg path "$path" --arg workspace "$workspace" --arg pane "$pane" \
  --argjson created "$created" --argjson moved "$moved" \
  '{path:$path, workspace_id:$workspace, pane_id:$pane, created:$created, moved:$moved}'
