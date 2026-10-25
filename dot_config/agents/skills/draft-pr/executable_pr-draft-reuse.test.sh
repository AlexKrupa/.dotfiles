#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/pr-draft-reuse.sh"
d=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$d"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}
key() { sed -n "s/^$1=//p" <<<"$2"; }
draft() {
  printf -- '---\ntype: fix\nbase: main\ndiff-base: %s\ndiff-head: %s\n---\n\n# Title\n' "$1" "$2" \
    >"$d/draft.md"
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir "$d/repo" && cd "$d/repo" && git init -q -b main
printf 'a1\na2\n' >a.txt
printf 'b1\n' >b.txt
git add -A && git commit -qm base
base1=$(git rev-parse HEAD)
git switch -qc feature
printf 'a1\nA2\n' >a.txt
git commit -qam v1
v1=$(git rev-parse HEAD)

out=$("$script" "$d/none.md" main)
check "no file: reuse" no "$(key reuse "$out")"
check "no file: reason" no-file "$(key reason "$out")"
check "no file: diff-base" "$base1" "$(key diff-base "$out")"
check "no file: diff-head" "$v1" "$(key diff-head "$out")"

printf -- '---\ntype: fix\nbase: main\n---\n\n# Title\n' >"$d/draft.md"
out=$("$script" "$d/draft.md" main)
check "no record: reuse" no "$(key reuse "$out")"
check "no record: reason" no-record "$(key reason "$out")"

draft "$base1" "$v1"
out=$("$script" "$d/draft.md" main)
check "same base, same head: reuse" yes "$(key reuse "$out")"
check "same base, same head: reason" unchanged "$(key reason "$out")"

git switch -q main
printf 'b1\nb2\n' >b.txt
git commit -qam main2
base2=$(git rev-parse HEAD)
git switch -q feature
git rebase -q main
v2=$(git rev-parse HEAD)
out=$("$script" "$d/draft.md" main)
check "rebase, same content: reuse" yes "$(key reuse "$out")"
check "rebase, same content: reason" unchanged "$(key reason "$out")"
check "rebase, same content: diff-base" "$base2" "$(key diff-base "$out")"
check "rebase, same content: diff-head" "$v2" "$(key diff-head "$out")"

draft "$base2" "$v2"
printf 'a1\nX2\n' >a.txt
git commit -q --amend -am v1
out=$("$script" "$d/draft.md" main)
check "amend changes content: reuse" no "$(key reuse "$out")"
check "amend changes content: reason" changed "$(key reason "$out")"

draft "$base2" 0000000000000000000000000000000000000000
out=$("$script" "$d/draft.md" main)
check "unknown commit: reuse" no "$(key reuse "$out")"
check "unknown commit: reason" unknown-commit "$(key reason "$out")"

# A failed interdiff must not read as "no content change".
mkdir -p "$d/stub/skills/draft-pr" "$d/stub/bin"
cp "$script" "$d/stub/skills/draft-pr/"
printf '#!/bin/sh\necho "git-interdiff: broken" >&2\nexit 1\n' >"$d/stub/bin/git-interdiff.sh"
chmod +x "$d/stub/bin/git-interdiff.sh"
draft "$base2" "$v2"
"$d/stub/skills/draft-pr/pr-draft-reuse.sh" "$d/draft.md" main >/dev/null 2>&1; code=$?
check "failed interdiff: exit 1" 1 "$code"

"$script" >/dev/null 2>&1; code=$?
check "usage: exit 1" 1 "$code"
"$script" "$d/draft.md" no-such-ref >/dev/null 2>&1; code=$?
check "unknown parent: exit 1" 1 "$code"

exit $fail
