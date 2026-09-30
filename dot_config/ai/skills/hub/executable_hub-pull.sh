#!/usr/bin/env bash
# Usage: hub-pull.sh [--repo PATH] [--interval SECONDS] [--once]
# Keeps the checkout of a repo on the newest commit of the default branch of origin. Each interval,
# it fetches the branch and fast-forwards the checkout. It skips a round while a herdr agent other
# than $HERDR_PANE_ID runs in the checkout. It gives no output. --once: do one round, then stop.
# Exit codes: 0 --once done, 1 error: the checkout is on a different branch, has changes in
# tracked files, or cannot fast-forward, or 5 fetches in sequence failed, 3 a new instance replaced
# this one. A new instance stops an older instance of the same repo.
set -euo pipefail

die() { echo "hub-pull: $1" >&2; exit 1; }

repo=$PWD
interval=120
once=0
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo needs a path"; repo=$2; shift 2 ;;
    --interval) [[ $# -ge 2 ]] || die "--interval needs seconds"; interval=$2; shift 2 ;;
    --once) once=1; shift ;;
    *) die "unexpected argument: $1" ;;
  esac
done

command -v jq >/dev/null || die "jq is not installed"
cd "$repo" 2>/dev/null && top=$(git rev-parse --show-toplevel 2>/dev/null) \
  || die "not a git repo: $repo"
cd "$top"

origin_head() { git symbolic-ref --quiet --short refs/remotes/origin/HEAD; }
ref=$(origin_head || { git remote set-head origin --auto >/dev/null 2>&1 && origin_head; }) \
  || die "cannot find the default branch: origin/HEAD is not set"
default=${ref#origin/}

state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/hub
slug=$(~/.config/ai/bin/repo-slug.sh)
lock=$state_dir/$slug.pull.lock
mkdir -p "$state_dir"
# A new hub session replaces the old one: stop an older instance of this script that holds the lock.
# The command check stops no different program that got the PID of a dead instance.
old=$(cat "$lock" 2>/dev/null || true)
if [[ -n $old ]] && ps -o command= -p "$old" 2>/dev/null | grep -q 'hub-pull\.sh'; then
  kill "$old" 2>/dev/null || true
  for _ in {1..20}; do ps -p "$old" >/dev/null || break; sleep 0.5; done
  kill -KILL "$old" 2>/dev/null || true
fi
tmp=$(mktemp -d)
echo $$ >"$lock"
sleeper=''
cleanup() {
  if [[ -n $sleeper ]]; then kill "$sleeper" 2>/dev/null || true; fi
  rm -rf "$tmp"
  if [[ $(cat "$lock" 2>/dev/null) == "$$" ]]; then rm -f "$lock"; fi
}
trap cleanup EXIT
trap 'echo "hub-pull: replaced by a new hub pull" >&2; exit 3' TERM

# The parent of this script can be a wrapper shell that stays alive after the agent is killed,
# so the check covers all ancestors. `ps`, not `kill -0`: `kill -0` fails on processes of root.
ancestors=()
p=$PPID
while ((p > 1)); do ancestors+=("$p"); p=$(ps -o ppid= -p "$p" | tr -d ' '); done
parent_gone() {
  local p
  for p in "${ancestors[@]}"; do ps -p "$p" >/dev/null || return 0; done
  return 1
}

# Fast-forwards the checkout to origin/$default, or dies. Returns with no change while a different
# agent runs in the checkout.
update() {
  [[ $(git rev-parse HEAD) != $(git rev-parse "origin/$default") ]] || return 0
  local branch
  branch=$(git branch --show-current)
  [[ $branch == "$default" ]] || die "the checkout is on ${branch:-a detached HEAD}, not $default"
  git update-index -q --refresh
  git diff-index --quiet HEAD || die "the checkout has changes in tracked files"
  local agents
  agents=$(herdr agent list 2>/dev/null) || die "herdr agent list failed"
  if jq -e --arg top "$top" --arg me "${HERDR_PANE_ID:-}" '[.result.agents[]
      | select(.pane_id != $me and (.cwd // "" | . == $top or startswith($top + "/")))]
      | length > 0' <<<"$agents" >/dev/null; then
    return 0
  fi
  git merge --ff-only --quiet "origin/$default" >/dev/null 2>&1 \
    || die "cannot fast-forward $default to origin/$default"
}

fails=0
while :; do
  if git fetch --quiet origin "$default" 2>"$tmp/stderr"; then
    fails=0
    update
  else
    fails=$((fails + 1))
    if [[ $once == 1 || $fails -ge 5 ]]; then
      die "git fetch origin $default failed: $(paste -s -d ' ' "$tmp/stderr")"
    fi
  fi
  [[ $once == 0 ]] || exit 0
  # In the background: bash runs the TERM trap only after a foreground command ends.
  sleep "$interval" &
  sleeper=$!
  wait "$sleeper"
  sleeper=''
  parent_gone && die "the parent process is gone"
done
