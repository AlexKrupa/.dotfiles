#!/usr/bin/env bash
# Usage: git-interdiff.sh <old_base> <old_head> <new_base> <new_head>
# Prints the content change between two versions of an MR. Each version is a base (the merge
# base with the target) and a head. Writes nothing to the repo.
# Same base: the diff of the two heads. An amend that changes 3 lines gives a 3-line diff.
# Different base (a rebase): for each file of the two MR diffs whose patch changed, a diff of the
# old patch and the new patch. The changes of the target branch are not in the output.
# No output: no content change.
# Exit codes: 0 ok, 1 usage error or unknown commit
set -euo pipefail

die() { echo "git-interdiff: $1" >&2; exit 1; }

(($# == 4)) || die "usage: git-interdiff.sh <old_base> <old_head> <new_base> <new_head>"
for c; do git rev-parse -q --verify "$c^{commit}" >/dev/null || die "unknown commit: $c"; done
old_base=$1 old_head=$2 new_base=$3 new_head=$4

if [[ $(git rev-parse "$old_base") == $(git rev-parse "$new_base") ]]; then
  git --no-pager diff --no-color --no-ext-diff "$old_head" "$new_head"
  exit
fi

# The patch of one file, with no index line and no line numbers in the hunk headers. A rebase
# moves the line numbers, and that is not a content change.
patch_of() {
  git --no-pager diff --no-color --no-ext-diff "$1" "$2" -- "$3" \
    | sed -E '/^index /d; s/^@@ [^@]* @@/@@/'
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{ git diff --name-only "$old_base" "$old_head"; git diff --name-only "$new_base" "$new_head"; } \
  | sort -u | while IFS= read -r f; do
  patch_of "$old_base" "$old_head" "$f" >"$tmp/old"
  patch_of "$new_base" "$new_head" "$f" >"$tmp/new"
  cmp -s "$tmp/old" "$tmp/new" \
    || diff -u --label "old/$f" --label "new/$f" "$tmp/old" "$tmp/new" || true
done
