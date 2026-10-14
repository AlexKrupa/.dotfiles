#!/usr/bin/env bash
# Usage: ticket-id-rename.sh <placeholder> <ticket-id> [<branch>...] [--push] [--title TEXT]
# Puts the real ticket id in place of the placeholder id on git-spice branches (default: the
# current branch). The branches are one stack chain, each one directly on top of the next.
# - Branch names: <placeholder>/<rest> becomes <ticket-id>/<rest>, with git-spice.
# - Commits: the id in each message, and in each line that the chain adds to its base. Lines from
#   the base and the author and committer data stay. Branches above the chain get a restack.
# - Herdr: a label with the placeholder id, of a workspace that has a worktree of a branch.
# - --title: after the turn of the calling Claude session, bin/herdr-after-turn.sh submits
#   "/rename [<ticket-id>] <title>" in its pane. Outside Herdr, the script prints the command.
# A branch with an upstream stops the script before it changes anything, with a "pushed:" line
# for each branch, and the MR URL when git-spice knows it. With --push, the script pushes each
# new name and deletes the old remote branch.
# Prints "key: value" lines: branch, commits, pushed, workspace, restacked, session.
# Exit codes: 0 ok, 1 usage/other, 2 branches are pushed (no --push), 3 restack failed
set -euo pipefail

die() { echo "$1" >&2; exit "${2:-1}"; }
usage="usage: ticket-id-rename.sh <placeholder> <ticket-id> [<branch>...] [--push] [--title TEXT]"

placeholder="" ticket="" push=false title="" branches=()
while (($#)); do
  case "$1" in
    --push)  push=true; shift ;;
    --title) [[ $# -ge 2 ]] || die "--title needs text"; title=$2; shift 2 ;;
    -*)      die "unknown option: $1" ;;
    *)
      if [[ -z $placeholder ]]; then placeholder=$1
      elif [[ -z $ticket ]]; then ticket=$1
      else branches+=("$1"); fi
      shift ;;
  esac
done
[[ -n $placeholder && -n $ticket ]] || die "$usage"
((${#branches[@]})) || branches=("$(git branch --show-current)")

# "AB-0" does not match in "AB-01".
id_pattern='(?<!\w)\Q$ENV{OLD}\E(?!\w)'
with_id() { OLD=$placeholder NEW=$ticket perl -pe "s/$id_pattern/\$ENV{NEW}/g"; }
# with_id_on_lines <numbers>: with_id only on the lines with these numbers.
with_id_on_lines() {
  OLD=$placeholder NEW=$ticket ID_LINES=$1 perl -pe \
    "BEGIN { %n = map { \$_ => 1 } split ' ', \$ENV{ID_LINES} } s/$id_pattern/\$ENV{NEW}/g if \$n{\$.}"
}
new_name() { echo "$ticket/${1#"$placeholder"/}"; }

stack=$(git-spice log short --all --json) || die "git-spice log failed"
down_of() { jq -r --arg b "$1" 'select(.name == $b) | .down.name // empty' <<<"$stack"; }
in_set() { local b; for b in "${branches[@]}"; do [[ $b == "$1" ]] && return 0; done; return 1; }

for b in "${branches[@]}"; do
  [[ $b == "$placeholder"/* ]] || die "$b does not start with $placeholder/"
  ! git show-ref --verify --quiet "refs/heads/$(new_name "$b")" || die "branch $(new_name "$b") exists"
  [[ -n $(down_of "$b") ]] || die "git-spice does not track $b"
done

# Bottom to top.
chain=()
for b in "${branches[@]}"; do in_set "$(down_of "$b")" || chain+=("$b"); done
((${#chain[@]} == 1)) || die "${branches[*]} are not one git-spice stack chain"
while ((${#chain[@]} < ${#branches[@]})); do
  next=""
  for b in "${branches[@]}"; do [[ $(down_of "$b") == "${chain[-1]}" ]] && next=$b; done
  [[ -n $next ]] || die "${branches[*]} are not one git-spice stack chain"
  git merge-base --is-ancestor "${chain[-1]}" "$next" || die "$next needs a restack: run gs upstack restack"
  chain+=("$next")
done
top=${chain[-1]}
fork=$(git merge-base "$(down_of "${chain[0]}")" "${chain[0]}")
[[ -z $(git rev-list --merges "$fork..$top") ]] || die "$top has merge commits"

worktree_of() {
  git worktree list --porcelain \
    | awk -v ref="branch refs/heads/$1" '/^worktree /{ path = substr($0, 10) } $0 == ref { print path }'
}
for b in "${chain[@]}"; do
  wt=$(worktree_of "$b")
  [[ -z $wt || -z $(git -C "$wt" status --porcelain --untracked-files=no) ]] \
    || die "$wt has uncommitted changes"
done

pushed=()
for b in "${chain[@]}"; do
  upstream=$(git rev-parse --abbrev-ref "$b@{upstream}" 2>/dev/null) || continue
  pushed+=("$b")
  if $push; then
    remote=$(git config "branch.$b.remote")
    ! git ls-remote --exit-code --heads "$remote" "$(new_name "$b")" >/dev/null \
      || die "$remote has branch $(new_name "$b")"
  else
    url=$(jq -r --arg b "$b" 'select(.name == $b) | .change.url // empty' <<<"$stack")
    echo "pushed: $b $upstream${url:+ $url}"
  fi
done
((${#pushed[@]} == 0)) || $push || die "branches are pushed: run again with --push to rename them on the remote too" 2

# The worktree list has the old branch names only before the rename.
in_herdr=false
[[ ${HERDR_ENV-} == 1 ]] && in_herdr=true
if $in_herdr; then worktrees=$(herdr worktree list --cwd "$PWD"); fi

# Line numbers, for each file at commit $1, of the lines with the placeholder id that the chain
# adds to $fork: "<path>\t<number> <number>...".
added_lines() {
  git -c core.quotePath=false diff --no-color --no-ext-diff --no-prefix -U0 "$fork" "$1" \
    | OLD=$placeholder perl -ne "
        if (/^diff --git /) { \$header = 1; next }
        if (\$header && /^\+\+\+ (.*?)\t?\$/) { \$path = \$1; next }
        if (/^@@ -\S+ \+(\d+)/) { \$n = \$1; \$header = 0; next }
        next if \$header;
        if (/^\+/) { push @{\$lines{\$path}}, \$n if /$id_pattern/; \$n++ }
        END { print \"\$_\t@{\$lines{\$_}}\n\" for sort keys %lines }"
}

sign=()
[[ $(git config --bool commit.gpgSign || true) == true ]] && sign=(-S)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

old_tips=() new_tips=()
for b in "${chain[@]}"; do old_tips+=("$(git rev-parse "$b")"); done
new_tips=("${old_tips[@]}")
parent=$fork rewritten=0
for commit in $(git rev-list --reverse "$fork..$top"); do
  message=$(git show -s --format=%B "$commit")
  new_message=$(with_id <<<"$message")
  old_tree=$(git rev-parse "$commit^{tree}")
  tree=$old_tree
  lines=$(added_lines "$commit")
  if [[ -n $lines ]]; then
    GIT_INDEX_FILE=$tmp/index git read-tree "$commit"
    while IFS=$'\t' read -r path numbers; do
      mode=$(git ls-tree "$commit" -- "$path" | cut -d' ' -f1)
      blob=$(git cat-file blob "$commit:$path" | with_id_on_lines "$numbers" | git hash-object -w --stdin)
      GIT_INDEX_FILE=$tmp/index git update-index --cacheinfo "$mode,$blob,$path"
    done <<<"$lines"
    tree=$(GIT_INDEX_FILE=$tmp/index git write-tree)
  fi

  if [[ $parent == $(git rev-parse "$commit^") && $tree == "$old_tree" && $new_message == "$message" ]]; then
    new=$commit
  else
    IFS=$'\x1f' read -r an ae ad cn ce cd < <(git show -s --date=raw \
      --format='%an%x1f%ae%x1f%ad%x1f%cn%x1f%ce%x1f%cd' "$commit")
    new=$(GIT_AUTHOR_NAME=$an GIT_AUTHOR_EMAIL=$ae GIT_AUTHOR_DATE=$ad \
      GIT_COMMITTER_NAME=$cn GIT_COMMITTER_EMAIL=$ce GIT_COMMITTER_DATE=$cd \
      git commit-tree "${sign[@]}" "$tree" -p "$parent" <<<"$new_message")
    rewritten=$((rewritten + 1))
  fi
  for i in "${!old_tips[@]}"; do [[ ${old_tips[i]} != "$commit" ]] || new_tips[i]=$new; done
  parent=$new
done

for i in "${!chain[@]}"; do
  b=${chain[i]}
  wt=$(worktree_of "$b")
  if [[ -n $wt ]]; then git -C "$wt" reset -q --keep "${new_tips[i]}"
  else git update-ref "refs/heads/$b" "${new_tips[i]}" "${old_tips[i]}"; fi
  git-spice branch rename "$b" "$(new_name "$b")" >/dev/null 2>&1 \
    || die "git-spice branch rename failed: $b"
  echo "branch: $b -> $(new_name "$b")"
done
echo "commits: $rewritten rewritten"

for b in ${pushed[@]+"${pushed[@]}"}; do
  new=$(new_name "$b")
  remote=$(git config "branch.$new.remote")
  git push -q -u "$remote" "refs/heads/$new:refs/heads/$new"
  git push -q "$remote" --delete "$b"
  echo "pushed: $new (deleted $remote/$b)"
done

if $in_herdr; then
  for b in "${chain[@]}"; do
    workspace=$(jq -r --arg b "$b" \
      '.result.worktrees[] | select(.branch == $b) | .open_workspace_id // empty' <<<"$worktrees")
    [[ -n $workspace ]] || continue
    label=$(herdr workspace get "$workspace" | jq -r '.result.workspace.label')
    new_label=$(with_id <<<"$label")
    [[ $new_label != "$label" ]] || continue
    herdr workspace rename "$workspace" "$new_label" >/dev/null
    echo "workspace: $workspace $label -> $new_label"
  done
fi

ups=$(jq -r --arg b "$top" 'select(.name == $b) | .ups[]?.name' <<<"$stack" | paste -sd' ' -)
if [[ -n $ups ]]; then
  git-spice upstack restack --branch "$(new_name "$top")" >/dev/null 2>&1 \
    || die "restack of $ups stopped: fix the conflict, then run gs rebase continue" 3
  echo "restacked: $ups"
fi

if [[ -n $title ]]; then
  command="/rename [$ticket] $title"
  if $in_herdr; then
    pane=$(herdr pane current --current | jq -r '.result.pane.pane_id')
    nohup "$(dirname "$0")/herdr-after-turn.sh" "$pane" "$command" </dev/null \
      >>"${TMPDIR:-/tmp}/ticket-id-rename.log" 2>&1 &
    echo "session: queued $command"
  else
    echo "session: manual $command"
  fi
fi
