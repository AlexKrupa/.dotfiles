#!/usr/bin/env bash
# Usage: work-start.sh mode
#        work-start.sh <ticket-id> <slug-text> [--base REF] [-- <claude flags>...]
#        work-start.sh <ticket-id> --branch NAME [-- <claude flags>...]
# Starts work on a ticket. Reads the first prompt on stdin. Branch: <ticket-id>/<slug>.
# Mode "new" (main checkout): creates the branch from the default branch of origin (origin/HEAD)
# after a fast-forward, or from the remote ref REF. Tracks it on the default branch with
# git-spice. Opens it as a new herdr worktree workspace, starts Claude there, and submits the
# prompt.
# Mode "next" (linked worktree): creates the branch on top of the current branch with git-spice.
# Then starts work-next.sh, which clears this Claude session after the turn and submits the prompt.
# Mode "existing" (--branch, from any worktree): fast-forwards the local branch NAME to origin, or
# creates it from origin. Then the same as "new" mode, with no git-spice tracking. A worktree of
# NAME is used again. A workspace that is open already stops the script.
# Prints JSON: mode, branch, base, tracked, worktree, pane_id, and in new and existing mode
# workspace_id, agent.
# Exit codes: 0 ok, 1 failed before the branch exists, 2 failed after it, 3 agent not ready
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
bin=$(cd "$here/../../bin" && pwd)
WORK_NEXT=${WORK_NEXT:-$here/work-next.sh}
spice_ref=refs/spice/data

die() { echo "work-start: $1" >&2; exit 1; }
fail() { echo "work-start: $1 (branch $branch stays)" >&2; exit 2; }

# "new" in the main worktree, "next" in a linked worktree.
mode_of() {
  local git_dir common_dir
  git_dir=$(cd "$(git rev-parse --git-dir)" && pwd -P)
  common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  if [[ $git_dir == "$common_dir" ]]; then echo new; else echo next; fi
}

# slugify <text> <max length>: lowercase ASCII words joined by hyphens. Longer than the max
# length: cut at a word end.
slugify() {
  local s max=$2
  s=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  if ((${#s} > max)); then
    if [[ ${s:max:1} == - ]]; then
      s=${s:0:max}
    else
      s=${s:0:max}
      [[ $s != *-* ]] || s=${s%-*}
    fi
  fi
  printf '%s' "$s"
}

git rev-parse --git-dir >/dev/null 2>&1 || die "not in a git repo: $PWD"
if [[ ${1:-} == mode && $# -eq 1 ]]; then mode_of; exit 0; fi

ticket="" text="" base="" existing="" claude_args=()
while (($#)); do
  case "$1" in
    --base) [[ $# -ge 2 ]] || die "--base needs a ref"; base=$2; shift 2 ;;
    --branch) [[ $# -ge 2 ]] || die "--branch needs a name"; existing=$2; shift 2 ;;
    --) shift; claude_args=("$@"); break ;;
    -*) die "unknown option: $1" ;;
    *)
      if [[ -z $ticket ]]; then ticket=$1
      elif [[ -z $text ]]; then text=$1
      else die "unexpected argument: $1"; fi
      shift ;;
  esac
done

if [[ -n $existing ]]; then
  [[ -n $ticket && -z $text && -z $base ]] \
    || die "usage: work-start.sh <ticket-id> --branch NAME [-- <claude flags>...]"
  branch=$existing
else
  [[ -n $ticket && -n $text ]] \
    || die "usage: work-start.sh <ticket-id> <slug-text> [--base REF] [-- <claude flags>...]"
  slug=$(slugify "$text" 40)
  [[ -n $slug ]] || die "slug text has no letters or digits: $text"
  branch="$ticket/$slug"
fi
git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "not a valid branch name: $branch"
prompt=$(cat)
[[ -n $prompt ]] || die "no prompt text on stdin"

if [[ -z $existing ]]; then
  if git show-ref --verify --quiet "refs/heads/$branch"; then die "branch exists: $branch"; fi
  git show-ref --verify --quiet "$spice_ref" \
    || die "git-spice is not set up: run 'gs repo init' first"
fi

if [[ -z $existing && $(mode_of) == next ]]; then
  [[ -z $base ]] || die "--base does not apply in a linked worktree"
  ((${#claude_args[@]} == 0)) || die "claude flags do not apply in a linked worktree"
  [[ -z $(git status --porcelain) ]] || die "the worktree has changes: the old work is not done"
  old=$(git branch --show-current)
  [[ -n $old ]] || die "detached HEAD: check out a branch first"
  pane=$(herdr pane current --current | jq -r '.result.pane.pane_id // empty') || true
  [[ -n $pane ]] || die "cannot find the herdr pane of this session"

  if ! out=$(git-spice branch create "$branch" --no-commit 2>&1); then
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      fail "git-spice branch create failed: $out"
    fi
    die "git-spice branch create failed: $out"
  fi

  # Detached, so it lives after this turn. It waits until the turn ends.
  nohup "$WORK_NEXT" "$pane" "$old" <<<"$prompt" >>"${TMPDIR:-/tmp}/work-next.log" 2>&1 &

  jq -n --arg branch "$branch" --arg base "$old" --arg pane "$pane" \
    --arg worktree "$(git rev-parse --show-toplevel)" \
    '{mode: "next", branch: $branch, base: $base, tracked: true, worktree: $worktree,
      pane_id: $pane}'
  exit 0
fi

origin_head() { git symbolic-ref --quiet --short refs/remotes/origin/HEAD; }
ref=$(origin_head || { git remote set-head origin --auto >/dev/null 2>&1 && origin_head; }) \
  || die "cannot find the default branch: origin/HEAD is not set"
default=${ref#origin/}

main=$(git worktree list --porcelain | awk -v ref="branch refs/heads/$default" \
  '/^worktree /{p = substr($0, 10)} $0 == ref {print p; exit}')
[[ -n $main ]] || die "no worktree has $default checked out"

if [[ -n $existing ]]; then
  if git -C "$main" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1; then
    out=$(cd "$main" && "$bin/fetch-gitlab-mr.sh" fetch "$branch" 2>&1) \
      || die "cannot update $branch: $out"
  elif ! git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
    die "branch not found in the local repo or on origin: $branch"
  fi

  opened=$("$bin/herdr-worktree.sh" "$branch" --repo "$main" 2>&1) \
    || die "herdr-worktree.sh failed: $opened"
  worktree=$(jq -r '.path' <<<"$opened")
  workspace=$(jq -r '.workspace_id' <<<"$opened")
  pane=$(jq -r '.root_pane_id' <<<"$opened")
  [[ -n $pane ]] || die "$branch is open in herdr workspace $workspace already"
  mode=existing base="" tracked=false
else
  git -C "$main" fetch --quiet origin || die "git fetch origin failed"

  if [[ -z $base ]]; then
    git -C "$main" merge --ff-only --quiet "origin/$default" >/dev/null 2>&1 \
      || die "cannot fast-forward $default to origin/$default in $main"
    base=$default
  else
    if git -C "$main" show-ref --verify --quiet "refs/heads/$base"; then
      die "base $base is a local branch: stack it in its worktree with /work"
    fi
    git -C "$main" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
      || die "base not found: $base"
  fi

  # No checkout: the main checkout stays on the default branch.
  git -C "$main" branch --no-track "$branch" "$base" >/dev/null \
    || die "git branch failed: $branch"

  # git-spice needs a local base branch, so a remote base gets no tracking.
  tracked=false
  if [[ $base == "$default" ]]; then
    git-spice -C "$main" branch track "$branch" --base "$default" >/dev/null 2>&1 \
      || fail "git-spice branch track failed"
    tracked=true
  fi

  made=$(herdr worktree create --cwd "$main" --branch "$branch" --no-focus) \
    || fail "herdr worktree create failed"
  worktree=$(jq -r '.result.worktree.path' <<<"$made")
  workspace=$(jq -r '.result.workspace.workspace_id' <<<"$made")
  pane=$(jq -r '.result.root_pane.pane_id' <<<"$made")
  mode=new
fi

# herdr agent names: a lowercase letter first, then [a-z0-9_-], 32 characters max.
name=$(slugify "$branch" 32)

start=(herdr agent start "$name" --kind claude --pane "$pane")
((${#claude_args[@]} == 0)) || start+=(-- "${claude_args[@]}")
if ! out=$("${start[@]}" 2>&1); then
  if grep -q agent_not_ready <<<"$out"; then
    echo "work-start: agent not ready in pane $pane (branch $branch stays)" >&2
    exit 3
  fi
  fail "herdr agent start failed: $out"
fi

herdr agent prompt "$pane" "$prompt" >/dev/null || fail "herdr agent prompt failed"

jq -n --arg mode "$mode" --arg branch "$branch" --arg base "$base" --argjson tracked "$tracked" \
  --arg worktree "$worktree" --arg workspace "$workspace" --arg pane "$pane" --arg agent "$name" \
  '{mode: $mode, branch: $branch, base: (if $base == "" then null else $base end),
    tracked: $tracked, worktree: $worktree, workspace_id: $workspace, pane_id: $pane,
    agent: $agent}'
