#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/git-interdiff.sh"
d=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$d" "$d.ext"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}
changed() { grep -E '^[-+][^-+]' | paste -sd' ' -; }
# Lines of a diff of two patches that changed: "-+old" and "++new", no file headers.
patch_changed() { grep -E '^[-+][-+][^-+ ]' | paste -sd' ' -; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
cd "$d" && git init -q -b main
# The user config can set an external diff tool, for example difftastic.
printf '#!/bin/sh\necho external diff\n' >"$d.ext" && chmod +x "$d.ext"
git config diff.external "$d.ext"
printf 'a1\na2\na3\n' >a.txt
printf 'b1\n' >b.txt
printf 's1\n' >'s p.txt'
git add -A && git commit -qm base
base1=$(git rev-parse HEAD)
git switch -qc feature
printf 'a1\nA2\na3\n' >a.txt
printf 'S1\n' >'s p.txt'
git commit -qam v1
v1=$(git rev-parse HEAD)

printf 'a1\nA2\nA3\n' >a.txt
git commit -q --amend -am v1
v2=$(git rev-parse HEAD)
out=$("$script" "$base1" "$v1" "$base1" "$v2")
check "amend: only the amended line" "-a3 +A3" "$(changed <<<"$out")"

git switch -q main
printf 'b1\nb2\n' >b.txt
git commit -qam main2
base2=$(git rev-parse HEAD)
git switch -q feature
git rebase -q main
v3=$(git rev-parse HEAD)
out=$("$script" "$base1" "$v2" "$base2" "$v3")
check "rebase with no content change: no output" "" "$out"

printf 'a1\nA2\nX3\n' >a.txt
printf 'T1\n' >'s p.txt'
git commit -q --amend -am v1
v4=$(git rev-parse HEAD)
out=$("$script" "$base1" "$v2" "$base2" "$v4")
check "rebase and amend: only the changed patch lines" "-+A3 ++X3 -+S1 ++T1" \
  "$(patch_changed <<<"$out")"
check "rebase and amend: no change of main" 0 "$(grep -c 'b.txt' <<<"$out")"

out=$("$script" "$base1" 0123456789abcdef0123456789abcdef01234567 "$base1" "$v2" 2>&1); code=$?
check "unknown commit: exit 1" 1 "$code"
check "unknown commit: message" \
  "git-interdiff: unknown commit: 0123456789abcdef0123456789abcdef01234567" "$out"

out=$("$script" "$base1" 2>&1); code=$?
check "usage error: exit 1" 1 "$code"
check "usage error: message" \
  "git-interdiff: usage: git-interdiff.sh <old_base> <old_head> <new_base> <new_head>" "$out"

exit $fail
