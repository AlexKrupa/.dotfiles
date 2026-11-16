#!/bin/sh
# Uses temporary repositories: a bare origin and a clone.
bin=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
  GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
repo=$tmp/clone
g() { git -C "$repo" "$@"; }
commit() { echo "$1" >"$repo/$1" && g add "$1" && g commit -qm "$1"; } # commit <file>
branch() { g switch -qc "$1" main && shift && for file; do commit "$file"; done; } # branch <name> <file>...
land() { g push -q origin main && g switch -q main; } # pushes main as the remote merge
exists() { g show-ref --verify --quiet "refs/heads/$1" && echo yes || echo no; }
run() { "$bin/delete-merged-branch.sh" "$@"; }

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$repo" 2>/dev/null
commit base
g push -q -u origin main
g remote set-head origin main

branch merged-ff a1
g switch -q main && g merge -q --ff-only merged-ff && land
run "$repo" merged-ff >/dev/null
check "deletes a fast-forwarded branch" no "$(exists merged-ff)"

branch squashed s1 s2
g switch -q main && g merge -q --squash squashed >/dev/null && g commit -qm squash && land
check "prints the result" "Branch squashed deleted: merged into origin/main" "$(run "$repo" squashed)"
check "deletes a squash-merged branch" no "$(exists squashed)"

branch rebased r1 r2
g switch -q main && commit other
g cherry-pick rebased~1 rebased >/dev/null && land
run "$repo" rebased >/dev/null
check "deletes a rebase-merged branch" no "$(exists rebased)"

branch open o1
g switch -q main
check "keeps an unmerged branch" "Branch open kept: not merged into origin/main" "$(run "$repo" open)"
check "the unmerged branch exists" yes "$(exists open)"
sha=$(g rev-parse --short open)
check "--force deletes an unmerged branch" "Branch open deleted: not merged, was $sha" \
  "$(run --force "$repo" open)"

git-spice -C "$repo" repo init --trunk main --remote origin --no-prompt 2>/dev/null
branch lower l1
branch upper u1
g rebase -q lower upper 2>/dev/null
git-spice -C "$repo" branch track --no-prompt --base main lower 2>/dev/null
git-spice -C "$repo" branch track --no-prompt --base lower upper 2>/dev/null
g switch -q main
check "--force keeps an unmerged branch with a branch above" \
  "Branch lower kept: not merged, 1 branches above it" "$(run --force "$repo" lower)"
g merge -q --squash lower >/dev/null && g commit -qm "squash lower" && land
check "deletes a merged stack branch" \
  "Branch lower deleted: merged into origin/main, 1 branches above it need a restack" \
  "$(run "$repo" lower)"
check "the branch above gets the new base" main \
  "$(git-spice -C "$repo" log short --all --json | jq -r 'select(.name == "upper") | .down.name')"

exit "$fail"
