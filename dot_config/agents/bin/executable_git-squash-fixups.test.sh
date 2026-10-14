#!/usr/bin/env bash
# Checks git-squash-fixups.sh with scratch repos. No LLM.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/git-squash-fixups.sh"
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

# new_repo <name>: sets $repo to a fresh repo on branch feat, one commit ahead of nothing.
new_repo() {
  repo="$tmp/$1"
  mkdir -p "$repo" && git -C "$repo" init -q -b main
  commit README.md "# R" Init
  git -C "$repo" switch -q -c feat
}
# commit <file> <content> <subject>
commit() { printf '%s\n' "$2" >"$repo/$1"; git -C "$repo" add -A; git -C "$repo" commit -q -m "$3"; }
tip() { git -C "$repo" rev-parse HEAD; }
run() { (cd "$repo" && "$script" "$@") >"$tmp/out" 2>"$tmp/err"; }
subjects() { git -C "$repo" log --reverse --format=%s main..HEAD | paste -sd, -; }
backups() { git -C "$repo" for-each-ref --format='%(objectname)' refs/review-me/; }

# --- guards ---

mkdir -p "$tmp/plain"
(cd "$tmp/plain" && "$script" main) >/dev/null 2>"$tmp/err"; code=$?
check "not a repo: exit 1" 1 "$code"
check "not a repo: message" "Not inside a git work tree." "$(cat "$tmp/err")"

new_repo guards
commit a.txt 1 A; a=$(tip)
commit b.txt 1 B; b=$(tip)
commit a.txt 2 C; c=$(tip)
commit b.txt 2 D; d=$(tip)
main=$(git -C "$repo" rev-parse main)

run; check "no args: exit 1" 1 "$?"
check "no args: message" \
  "Usage: git-squash-fixups.sh [--dry-run] <parent> [<repair>:<target>...]" "$(cat "$tmp/err")"

run nope
check "bad parent" "Parent ref 'nope' not found." "$(cat "$tmp/err")"

run HEAD
check "HEAD is parent" "HEAD == parent; no branch commits to rewrite." "$(cat "$tmp/err")"

run main "$c"
check "squash without colon" "Bad squash '$c'; expected <repair>:<target>." "$(cat "$tmp/err")"

run main "$c:$c"
check "squash into itself" "Squash '$c:$c' folds a commit into itself." "$(cat "$tmp/err")"

run main "$c:main"
check "target outside range" "Target ${main:0:7} is outside main..HEAD." "$(cat "$tmp/err")"

run main "$a:$c"
check "reversed squash" \
  "Target ${c:0:7} is not an ancestor of repair ${a:0:7}; use <newer>:<older>." "$(cat "$tmp/err")"

run main "$c:$a" "$c:$b"
check "repair twice" "Commit ${c:0:7} given as repair twice." "$(cat "$tmp/err")"

run main "$c:$a" "$d:$c"
check "target was a repair" "Commit ${c:0:7} is both a repair and a target." "$(cat "$tmp/err")"

run main "$d:$c" "$c:$a"
check "repair was a target" "Commit ${c:0:7} is both a repair and a target." "$(cat "$tmp/err")"

echo dirty >"$repo/a.txt"
run main
check "dirty tree" "Working tree not clean. Commit or stash first." "$(cat "$tmp/err")"
git -C "$repo" checkout -q -- a.txt

check "guards: HEAD unchanged" "$d" "$(tip)"
check "guards: no backup ref" "" "$(backups)"

new_repo merge
commit a.txt 1 A
git -C "$repo" switch -q -c side
commit s.txt 1 S
git -C "$repo" switch -q feat
commit b.txt 1 B
git -C "$repo" merge -q --no-ff side -m M
run main
check "merge in range" "Range contains merge commits; refusing to flatten history." "$(cat "$tmp/err")"

# --- dry run ---

new_repo dry
commit a.txt 1 A; a=$(tip)
commit b.txt 1 B
commit a.txt 2 C; c=$(tip)
run --dry-run main "$c:$a"; code=$?
check "dry run: exit 0" 0 "$code"
check "dry run: output" "dry-run: yes
commits-before: 3
planned-squashes: 1
  $(git -C "$repo" rev-parse --short "$c") C -> $(git -C "$repo" rev-parse --short "$a") A" \
  "$(cat "$tmp/out")"
check "dry run: HEAD unchanged" "$c" "$(tip)"
check "dry run: no backup ref" "" "$(backups)"

# --- one squash ---

new_repo one
commit a.txt 1 A; a=$(tip)
commit b.txt 1 B
commit a.txt 2 C; c=$(tip)
commit b.txt 2 D; old=$(tip)
tree=$(git -C "$repo" rev-parse HEAD^{tree})
run main "$c:$a"; code=$?
check "one squash: exit 0" 0 "$code"
check "one squash: subjects" "A,B,D" "$(subjects)"
check "one squash: repair in target" 2 "$(git -C "$repo" show HEAD~2:a.txt)"
check "one squash: same tree" "$tree" "$(git -C "$repo" rev-parse HEAD^{tree})"
check "one squash: backup ref" "$old" "$(backups)"
check "one squash: counts" "commits-before: 4
commits-after: 3
result: ok" "$(grep -E '^(commits-|result)' "$tmp/out")"

# --- two repairs for one target ---

# Each repair builds on the one before. The wrong order conflicts.
new_repo order
commit a.txt 1 A; a=$(tip)
commit b.txt 1 B
commit a.txt 2 R1; r1=$(tip)
commit a.txt 3 R2; r2=$(tip)
run main "$r1:$a" "$r2:$a"; code=$?
check "two repairs: exit 0" 0 "$code"
check "two repairs: subjects" "A,B" "$(subjects)"
check "two repairs: last repair wins" 3 "$(git -C "$repo" show HEAD~1:a.txt)"

new_repo order-args
commit a.txt 1 A; a=$(tip)
commit b.txt 1 B
commit a.txt 2 R1; r1=$(tip)
commit a.txt 3 R2; r2=$(tip)
run main "$r2:$a" "$r1:$a"; code=$?
check "two repairs, reversed args: exit 0" 0 "$code"
check "two repairs, reversed args: subjects" "A,B" "$(subjects)"

# --- repair and a pending fixup! for one target ---

# The fixup! commit builds on the repair, so it must stay after it.
new_repo pending-and-repair
commit a.txt 1 A; a=$(tip)
commit b.txt 1 B
commit a.txt 2 R; r=$(tip)
commit a.txt 3 "fixup! A"
run main "$r:$a"; code=$?
check "repair + fixup!: exit 0" 0 "$code"
check "repair + fixup!: subjects" "A,B" "$(subjects)"
check "repair + fixup!: fixup! wins" 3 "$(git -C "$repo" show HEAD~1:a.txt)"

# --- no squashes ---

new_repo pending
commit a.txt 1 A
commit b.txt 1 B
commit a.txt 2 "fixup! A"
run main; code=$?
check "pending only: exit 0" 0 "$code"
check "pending only: subjects" "A,B" "$(subjects)"
check "pending only: fixup in target" 2 "$(git -C "$repo" show HEAD~1:a.txt)"

# --- conflict ---

# C changes a.txt from 2 to 3. Moved onto A (a.txt is 1), it conflicts.
new_repo conflict
commit a.txt 1 A; a=$(tip)
commit a.txt 2 B
commit a.txt 3 C; c=$(tip)
run main "$c:$a"; code=$?
check "conflict: exit 1" 1 "$code"
check "conflict: message" "Rebase failed (conflict or bad todo). Branch restored to $c." \
  "$(sed 's/ Backup: .*//' "$tmp/err")"
check "conflict: HEAD restored" "$c" "$(tip)"
check "conflict: no rebase in progress" no \
  "$([ -e "$(git -C "$repo" rev-parse --path-format=absolute --git-path rebase-merge)" ] \
    && echo yes || echo no)"
check "conflict: clean tree" "" "$(git -C "$repo" status --porcelain)"
check "conflict: backup ref" "$c" "$(backups)"

# --- git config that changes the todo ---

new_repo config
git -C "$repo" config rebase.abbreviateCommands true
git -C "$repo" config rebase.instructionFormat '%an: %s'
commit a.txt 1 A; a=$(tip)
commit b.txt 1 B
commit a.txt 2 C; c=$(tip)
run main "$c:$a"; code=$?
check "short commands: exit 0" 0 "$code"
check "short commands: subjects" "A,B" "$(subjects)"
check "short commands: repair in target" 2 "$(git -C "$repo" show HEAD~1:a.txt)"

new_repo update-refs
git -C "$repo" config rebase.updateRefs true
commit a.txt 1 A; a=$(tip)
git -C "$repo" branch mid
commit b.txt 1 B
commit a.txt 2 C; c=$(tip)
run main "$c:$a"; code=$?
check "update-refs: exit 0" 0 "$code"
check "update-refs: subjects" "A,B" "$(subjects)"
check "update-refs: stacked branch moved" "$(git -C "$repo" rev-parse HEAD~1)" \
  "$(git -C "$repo" rev-parse mid)"

exit "$fail"
