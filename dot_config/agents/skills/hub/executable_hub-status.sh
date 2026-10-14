#!/usr/bin/env bash
# Usage: hub-status.sh [--repo PATH]
# Lists the herdr agents that run in the linked worktrees of a repo. One TSV line for each agent:
# pane_id, status, branch, cwd, title. The title is last, so an empty title does not move the
# other fields.
# Exit codes: 0 ok (no lines if no agent matches), 1 error
set -euo pipefail

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

agents=$(herdr agent list 2>/dev/null) || die "herdr agent list failed"
jq -r --arg linked "$linked" '
  ($linked | split("\n")) as $paths
  | .result.agents[]
  | select((.cwd // "") as $cwd
      | any($paths[]; . as $p | $cwd == $p or ($cwd | startswith($p + "/"))))
  | [.pane_id, .agent_status, .cwd,
     ((.terminal_title_stripped // "") | gsub("[\t\n\r]"; " "))]
  | @tsv' <<<"$agents" \
  | while IFS=$'\t' read -r pane status cwd title; do
      branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
      printf '%s\t%s\t%s\t%s\t%s\n' "$pane" "$status" "$branch" "$cwd" "$title"
    done
