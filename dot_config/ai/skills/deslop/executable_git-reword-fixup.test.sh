#!/usr/bin/env bash
# Checks git-reword-fixup.sh with scratch repos. No LLM.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/git-reword-fixup.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Global config enables 1Password commit signing, which fails headless.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null HOME="$tmp/home"
export GIT_AUTHOR_NAME="Test Dev" GIT_AUTHOR_EMAIL=dev@example.com
export GIT_COMMITTER_NAME="Test Dev" GIT_COMMITTER_EMAIL=dev@example.com
mkdir -p "$HOME"

# commit <file> <content> <subject>
commit() { printf '%s\n' "$2" >"$repo/$1"; git -C "$repo" add -A; git -C "$repo" commit -q -m "$3"; }
tip() { git -C "$repo" rev-parse HEAD; }
run() { (cd "$repo" && "$script" "$@") >"$tmp/out" 2>"$tmp/err"; }
subjects() { git -C "$repo" log --reverse --format=%s main..HEAD | paste -sd, -; }

# Init on main, then on branch feat: A, B.
repo="$tmp/repo"
mkdir -p "$repo" && git -C "$repo" init -q -b main
commit README.md "# R" Init; init=$(tip)
commit README.md "# R2" Base
git -C "$repo" switch -q -c feat
commit a.txt 1 A; a=$(tip)
commit b.txt 1 B; b=$(tip)
printf 'A better\n\nBody line.\n' >"$tmp/msg"

# --- guards ---

mkdir -p "$tmp/plain"
(cd "$tmp/plain" && "$script" main HEAD "$tmp/msg") >/dev/null 2>"$tmp/err"; code=$?
check "not a repo: exit 1" 1 "$code"
check "not a repo: message" "Not inside a git work tree." "$(cat "$tmp/err")"

run main "$a"; check "two args: exit 1" 1 "$?"
check "two args: message" "Usage: git-reword-fixup.sh <parent> <sha> <message-file>" \
  "$(cat "$tmp/err")"

: >"$tmp/empty"
run main "$a" "$tmp/empty"
check "empty message file" "Message file missing or empty: $tmp/empty" "$(cat "$tmp/err")"

run nope "$a" "$tmp/msg"
check "bad parent" "Parent ref 'nope' not found." "$(cat "$tmp/err")"

run main nope "$tmp/msg"
check "bad commit" "Commit 'nope' not found." "$(cat "$tmp/err")"

run main main "$tmp/msg"
check "target is parent" "Refusing to reword the parent commit." "$(cat "$tmp/err")"

run main "$init" "$tmp/msg"
check "target outside range" "Commit $init is outside main..HEAD." "$(cat "$tmp/err")"

printf 'B\n' >"$tmp/same"
run main "$b" "$tmp/same"
check "same message" "New message is identical to the current one - nothing to reword." \
  "$(cat "$tmp/err")"

echo 2 >"$repo/b.txt"; git -C "$repo" add b.txt
run main "$b" "$tmp/msg"
check "index not empty" "Index not empty - commit or reset it first." "$(cat "$tmp/err")"
git -C "$repo" reset -q --hard

check "guards: no commit" "A,B" "$(subjects)"

# --- reword ---

run main "$a" "$tmp/msg"; code=$?
check "reword: exit 0" 0 "$code"
check "reword: output" "reword-fixup: $(git -C "$repo" rev-parse --short "$a") A better" \
  "$(cat "$tmp/out")"
check "reword: amend! commit" "amend! A

A better

Body line." "$(git -C "$repo" log -1 --format=%B)"
check "reword: empty commit" "" "$(git -C "$repo" diff --name-only HEAD~1 HEAD)"

(cd "$repo" && GIT_SEQUENCE_EDITOR=true GIT_EDITOR=true git rebase -q -i --autosquash main)
check "autosquash: subjects" "A better,B" "$(subjects)"
check "autosquash: message" "A better

Body line." "$(git -C "$repo" log -1 --format=%B HEAD~1)"
check "autosquash: content kept" 1 "$(git -C "$repo" show HEAD~1:a.txt)"

# --- duplicate subject ---

commit c.txt 1 B
run main "$(tip)" "$tmp/msg"
check "duplicate subject" "Subject 'B' appears 2 times in main..HEAD - cannot target it." \
  "$(cat "$tmp/err")"

exit "$fail"
