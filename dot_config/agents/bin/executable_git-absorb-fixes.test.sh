#!/usr/bin/env bash
# Checks git-absorb-fixes.sh with scratch repos and the real git-absorb. No LLM.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/git-absorb-fixes.sh"
command -v git-absorb >/dev/null 2>&1 || { echo "skip: git-absorb not installed"; exit 0; }
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

# new_repo <name>: sets $repo to a fresh repo with m.txt on main, then on branch feat:
# A adds a.txt, B adds b.txt. Sets $a to the A commit.
new_repo() {
  repo="$tmp/$1"
  mkdir -p "$repo" && git -C "$repo" init -q -b main
  # git absorb skips commits whose author is not the configured user. It ignores GIT_AUTHOR_*.
  git -C "$repo" config user.name "Test Dev"
  git -C "$repo" config user.email dev@example.com
  commit m.txt 'm1\nm2\nm3' Init
  git -C "$repo" switch -q -c feat
  commit a.txt 'a1\na2\na3' A; a=$(git -C "$repo" rev-parse --short HEAD)
  commit b.txt 'b1' B
}
# commit <file> <content> <subject>. Content takes printf escapes.
commit() { write "$1" "$2"; git -C "$repo" add -A; git -C "$repo" commit -q -m "$3"; }
write() { printf "$2\n" >"$repo/$1"; }
run() { (cd "$repo" && "$script" "$@") >"$tmp/out" 2>"$tmp/err"; }
subjects() { git -C "$repo" log --reverse --format=%s main..HEAD | paste -sd, -; }
staged() { git -C "$repo" diff --cached --name-only | paste -sd, -; }

# --- guards ---

mkdir -p "$tmp/plain"
(cd "$tmp/plain" && "$script" main a.txt) >/dev/null 2>"$tmp/err"; code=$?
check "not a repo: exit 1" 1 "$code"
check "not a repo: message" "Not inside a git work tree." "$(cat "$tmp/err")"

new_repo guards
run main; check "one arg: exit 1" 1 "$?"
check "one arg: message" "Usage: git-absorb-fixes.sh <parent> <file>..." "$(cat "$tmp/err")"

run nope a.txt
check "bad parent" "Parent ref 'nope' not found." "$(cat "$tmp/err")"

run HEAD a.txt
check "HEAD is parent" "HEAD == parent; nothing to absorb into." "$(cat "$tmp/err")"

run main nope.txt
check "missing file" "File not found and not tracked: nope.txt" "$(cat "$tmp/err")"

write b.txt 'b2'; git -C "$repo" add b.txt
run main a.txt
check "pre-staged index" "Index not empty before staging — refusing to mix in pre-staged changes." \
  "$(cat "$tmp/err")"
git -C "$repo" reset -q --hard

run main a.txt; code=$?
check "unchanged file: exit 0" 0 "$code"
check "unchanged file: output" "absorb-fixups: 0
blame-fixups: 0
needs-message: 0
staged-remaining: no" "$(cat "$tmp/out")"
check "unchanged file: no commit" "A,B" "$(subjects)"

# --- git absorb places the hunk ---

new_repo absorb
write a.txt 'a1\nA2\na3'
run main a.txt; code=$?
check "absorb: exit 0" 0 "$code"
check "absorb: output" "absorb-fixups: 1
blame-fixups: 0
needs-message: 0
staged-remaining: no" "$(cat "$tmp/out")"
check "absorb: subjects" "A,B,fixup! A" "$(subjects)"

# Unrelated work in the tree must stay unstaged and out of every commit.
new_repo unrelated
write a.txt 'a1\nA2\na3'
write b.txt 'B1'
run main a.txt; code=$?
check "unrelated change: exit 0" 0 "$code"
check "unrelated change: subjects" "A,B,fixup! A" "$(subjects)"
check "unrelated change: still unstaged" "b.txt" "$(git -C "$repo" diff --name-only)"
check "unrelated change: not staged" "" "$(staged)"

# --- blame fallback ---
# A different configured user makes git absorb skip all commits, as for a teammate's branch.

new_repo blame
git -C "$repo" config user.name "Other Dev"
write a.txt 'a1\nA2\na3'
run main a.txt; code=$?
check "blame: exit 0" 0 "$code"
check "blame: output" "absorb-fixups: 0
blame-fixups: 1
  $a a.txt
needs-message: 0
staged-remaining: no" "$(cat "$tmp/out")"
check "blame: subjects" "A,B,fixup! A" "$(subjects)"

# Two old lines blame Init (outside the range), one blames C. C is the dominant in-range SHA.
new_repo blame-mixed
git -C "$repo" config user.name "Other Dev"
commit m.txt 'm1\nm2\nA3' C; c=$(git -C "$repo" rev-parse --short HEAD)
commit b.txt 'b2' D
write m.txt 'M1\nM2\nM3'
run main m.txt; code=$?
check "blame mixed: exit 0" 0 "$code"
check "blame mixed: output" "absorb-fixups: 0
blame-fixups: 1
  $c m.txt
needs-message: 0
staged-remaining: no" "$(cat "$tmp/out")"

new_repo outside
write m.txt 'M1\nm2\nm3'
run main m.txt; code=$?
check "outside range: exit 0" 0 "$code"
check "outside range: output" "absorb-fixups: 0
blame-fixups: 0
needs-message: 1
  m.txt
staged-remaining: yes" "$(cat "$tmp/out")"
check "outside range: left staged" "m.txt" "$(staged)"
check "outside range: no commit" "A,B" "$(subjects)"

new_repo new-file
write c.txt 'c1'
run main c.txt; code=$?
check "new file: exit 0" 0 "$code"
check "new file: output" "absorb-fixups: 0
blame-fixups: 0
needs-message: 1
  c.txt
staged-remaining: yes" "$(cat "$tmp/out")"
check "new file: left staged" "c.txt" "$(staged)"

exit "$fail"
