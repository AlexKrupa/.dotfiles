#!/usr/bin/env bash
# Usage: hub-status.sh [--repo PATH]
# Lists the multiplexer agents that run in the linked worktrees of a repo. One TSV line for each
# agent: pane_id, status, branch, cwd, title. The title is last, so an empty title does not move
# the other fields.
# Exit codes: 0 ok (no lines if no agent matches), 1 error
set -euo pipefail

bin=$(cd "$(dirname "$0")/../../bin" && pwd)

die() { echo "hub-status: $1" >&2; exit 1; }

repo=$PWD
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo needs a path"; repo=$2; shift 2 ;;
    *) die "unexpected argument: $1" ;;
  esac
done

list=$(git -C "$repo" worktree list --porcelain 2>/dev/null) || die "not a git repo: $repo"
# git lists the main worktree first. The others are the linked worktrees.
linked=$(awk '/^worktree /{print substr($0, 10)}' <<<"$list" | tail -n +2)
[[ -n $linked ]] || exit 0

agents=$("$bin/mux.sh" agent-list 2>/dev/null) || die "agent-list failed"
# Only the title can be empty in a matching line, so `read` with a tab IFS keeps the fields.
LINKED=$linked awk -F'\t' '
  BEGIN { count = split(ENVIRON["LINKED"], paths, "\n") }
  {
    for (i = 1; i <= count; i++)
      if ($3 == paths[i] || index($3, paths[i] "/") == 1) { print; next }
  }' <<<"$agents" \
  | while IFS=$'\t' read -r pane status cwd title; do
      branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
      printf '%s\t%s\t%s\t%s\t%s\n' "$pane" "$status" "$branch" "$cwd" "$title"
    done
