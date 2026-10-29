#!/usr/bin/env bash
# Usage: pr-draft-reuse.sh <draft-file> <parent>
# Tells if a PR draft can stay as it is: the branch's own diff did not change since the draft got
# its text. Reads `diff-base` and `diff-head` from the frontmatter of the draft. A rebase onto a
# new base with no content change keeps the draft. Prints one `key: value` per line:
#   reuse: yes|no
#   reason: unchanged|changed|no-file|no-record|unknown-commit
#   diff-base: <merge base of <parent> and HEAD>
#   diff-head: <HEAD>
# Writes nothing to the repo.
# Exit codes: 0 ok, 1 usage error, unknown parent, or a failed git-interdiff.sh
set -euo pipefail

# pwd -P: the skill folder of an agent can be a link to this folder.
here=$(cd "$(dirname "$0")" && pwd -P)
bin=$here/../../bin

die() { echo "pr-draft-reuse: $1" >&2; exit 1; }

(($# == 2)) || die "usage: pr-draft-reuse.sh <draft-file> <parent>"
draft=$1 parent=$2
git rev-parse -q --verify "$parent^{commit}" >/dev/null || die "unknown parent: $parent"
new_base=$(git merge-base "$parent" HEAD)
new_head=$(git rev-parse HEAD)

result() {
  printf 'reuse: %s\nreason: %s\ndiff-base: %s\ndiff-head: %s\n' "$1" "$2" "$new_base" "$new_head"
  exit 0
}

[[ -f $draft ]] || result no no-file
# The value of one field of the frontmatter: the lines between the first two `---` lines.
field() { awk -v key="$1" 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit }
  NR > 1 && index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }' "$draft"; }
old_base=$(field diff-base)
old_head=$(field diff-head)
[[ -n $old_base && -n $old_head ]] || result no no-record
for c in "$old_base" "$old_head"; do
  git rev-parse -q --verify "$c^{commit}" >/dev/null || result no unknown-commit
done

interdiff=$("$bin/git-interdiff.sh" "$old_base" "$old_head" "$new_base" "$new_head") \
  || die "git-interdiff.sh failed"
if [[ -z $interdiff ]]; then result yes unchanged; else result no changed; fi
