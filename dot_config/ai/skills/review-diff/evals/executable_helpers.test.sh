#!/usr/bin/env bash
# Checks the deterministic review-diff helpers: git-diff-context.sh, docs-index.sh,
# review-report-path.sh. Uses scratch repos and a scratch HOME. No LLM.
set -u

skill=$(cd "$(dirname "$0")/.." && pwd)
bin=$(cd "$skill/../../bin" && pwd)
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
today=$(date +%F)

new_repo() { mkdir -p "$1" && git -C "$1" init -q -b main && commit_file "$1" README.md "# R"; }
commit_file() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" >"$1/$2"; git -C "$1" add -A; git -C "$1" commit -q -m "$2"; }
ctx() { (cd "$1" && shift && "$bin/git-diff-context.sh" "$@" 2>"$tmp/stderr"); }
key() { sed -n "s/^$1: //p"; }

# --- git-diff-context.sh ---

mkdir -p "$tmp/plain"
(cd "$tmp/plain" && "$bin/git-diff-context.sh" >/dev/null 2>"$tmp/stderr"); code=$?
check "context: not a repo exits 1" 1 "$code"
check "context: not a repo message" "Not inside a git work tree — nothing to review." "$(cat "$tmp/stderr")"

new_repo "$tmp/solo"
git -C "$tmp/solo" switch -q -c feat/empty
ctx "$tmp/solo" >/dev/null; code=$?
check "context: no diff exits 1" 1 "$code"
check "context: no diff message" "Branch 'feat/empty' has no diff vs parent 'main' — nothing to review." \
  "$(tail -1 "$tmp/stderr")"

commit_file "$tmp/solo" a.txt a
out=$(ctx "$tmp/solo")
check "context: no remote - parent" "main" "$(key parent <<<"$out")"
check "context: no remote - source" "default-branch" "$(key parent-source <<<"$out")"
check "context: no remote - fetched" "no" "$(key parent-fetched <<<"$out")"
check "context: no remote - warning" "warning: no remote for main; using local main (may be stale)" "$(cat "$tmp/stderr")"
check "context: diff-command" "git diff main...HEAD" "$(key diff-command <<<"$out")"
check "context: clean tree" "no" "$(key uncommitted <<<"$out")"

printf 'x\n' >"$tmp/solo/untracked.txt"
out=$(ctx "$tmp/solo")
check "context: uncommitted flag" "yes" "$(key uncommitted <<<"$out")"
check "context: uncommitted block" "?? untracked.txt" \
  "$(sed -n '/^## Uncommitted/{n;p;}' <<<"$out")"
rm "$tmp/solo/untracked.txt"

ctx "$tmp/solo" nope >/dev/null; code=$?
check "context: missing override exits 1" 1 "$code"
check "context: missing override message" "Override parent ref 'nope' not found." "$(cat "$tmp/stderr")"

# Remote mainline: local main is stale, origin/main has a newer commit.
new_repo "$tmp/remote"
git init -q --bare -b main "$tmp/remote.git"
git -C "$tmp/remote" remote add origin "$tmp/remote.git"
git -C "$tmp/remote" push -q -u origin main
git -C "$tmp/remote" remote set-head origin main >/dev/null
git clone -q "$tmp/remote.git" "$tmp/other"
commit_file "$tmp/other" other.txt other
git -C "$tmp/other" push -q origin main
git -C "$tmp/remote" switch -q -c feat/x
commit_file "$tmp/remote" x.txt x
out=$(ctx "$tmp/remote")
check "context: remote - parent" "origin/main" "$(key parent <<<"$out")"
check "context: remote - fetched" "yes" "$(key parent-fetched <<<"$out")"
check "context: remote - fetched the new commit" "$(git -C "$tmp/other" rev-parse HEAD)" \
  "$(git -C "$tmp/remote" rev-parse origin/main)"

# Stack: main <- feat/a <- feat/b.
new_repo "$tmp/stack"
git -C "$tmp/stack" switch -q -c feat/a
commit_file "$tmp/stack" a.txt a
git -C "$tmp/stack" switch -q -c feat/b
commit_file "$tmp/stack" b.txt b
out=$(ctx "$tmp/stack")
check "context: stack - parent" "feat/a" "$(key parent <<<"$out")"
check "context: stack - source" "ancestor-branch" "$(key parent-source <<<"$out")"
check "context: stack - commits" "1" "$(sed -n '/^## Commits/,/^$/p' <<<"$out" | grep -c '^[0-9a-f]\{7,\} ')"
out=$(ctx "$tmp/stack" main)
check "context: override - parent" "main" "$(key parent <<<"$out")"
check "context: override - source" "override" "$(key parent-source <<<"$out")"
check "context: branch - scope" "branch" "$(key scope <<<"$out")"
check "context: branch - tip" "feat/b" "$(key tip <<<"$out")"
check "context: branch - log-range" "main..HEAD" "$(key log-range <<<"$out")"
check "context: branch - report-prefix" "" "$(key report-prefix <<<"$out")"

# --uncommitted: branch commits plus working tree.
printf 'b2\n' >"$tmp/stack/b.txt"
printf 'n\n' >"$tmp/stack/new.txt"
out=$(ctx "$tmp/stack" --uncommitted)
check "context: uncommitted - scope" "uncommitted" "$(key scope <<<"$out")"
check "context: uncommitted - parent" "feat/a" "$(key parent <<<"$out")"
check "context: uncommitted - diff-command" "git diff --merge-base feat/a" "$(key diff-command <<<"$out")"
check "context: uncommitted - log-range" "feat/a..HEAD" "$(key log-range <<<"$out")"
check "context: uncommitted - report-prefix" "uncommitted" "$(key report-prefix <<<"$out")"
check "context: uncommitted - diffstat has the edit" "1" \
  "$(sed -n '/^## Diffstat/,/^$/p' <<<"$out" | grep -c 'b.txt')"
out=$(ctx "$tmp/stack" --uncommitted main)
check "context: uncommitted - override" "git diff --merge-base main" "$(key diff-command <<<"$out")"

# --staged: branch commits plus index, not the unstaged edit.
git -C "$tmp/stack" add new.txt
out=$(ctx "$tmp/stack" --staged)
check "context: staged - scope" "staged" "$(key scope <<<"$out")"
check "context: staged - diff-command" "git diff --cached --merge-base feat/a" "$(key diff-command <<<"$out")"
check "context: staged - diffstat" " b.txt   | 1 +| new.txt | 1 +" \
  "$(sed -n '/^## Diffstat/,/^$/p' <<<"$out" | grep '|' | paste -sd'|' -)"
git -C "$tmp/stack" reset -q && git -C "$tmp/stack" checkout -q -- b.txt && rm "$tmp/stack/new.txt"

# Uncommitted edits on the parent itself: HEAD equals parent.
git -C "$tmp/solo" switch -q main
ctx "$tmp/solo" --uncommitted >/dev/null; code=$?
check "context: uncommitted - nothing exits 1" 1 "$code"
check "context: uncommitted - nothing message" \
  "No committed or uncommitted changes vs parent 'main' — nothing to review." "$(tail -1 "$tmp/stderr")"
printf 'u\n' >"$tmp/solo/untracked.txt"
out=$(ctx "$tmp/solo" --uncommitted)
check "context: uncommitted - untracked only is a diff" "uncommitted" "$(key scope <<<"$out")"
ctx "$tmp/solo" --staged >/dev/null; code=$?
check "context: staged - nothing exits 1" 1 "$code"
check "context: staged - nothing message" \
  "No committed or staged changes vs parent 'main' — nothing to review." "$(tail -1 "$tmp/stderr")"
rm "$tmp/solo/untracked.txt"
git -C "$tmp/solo" switch -q feat/empty

# --rev: one commit or a range, independent of the current branch.
a_sha=$(git -C "$tmp/stack" rev-parse --short feat/a)
out=$(ctx "$tmp/stack" --rev "$a_sha")
check "context: rev - scope" "rev" "$(key scope <<<"$out")"
check "context: rev - parent" "$a_sha^" "$(key parent <<<"$out")"
check "context: rev - parent-source" "rev" "$(key parent-source <<<"$out")"
check "context: rev - tip" "$a_sha" "$(key tip <<<"$out")"
check "context: rev - diff-command" "git diff $a_sha^...$a_sha" "$(key diff-command <<<"$out")"
check "context: rev - log-range" "$a_sha^..$a_sha" "$(key log-range <<<"$out")"
check "context: rev - report-prefix" "$a_sha" "$(key report-prefix <<<"$out")"
check "context: rev - diffstat" " a.txt | 1 +" "$(sed -n '/^## Diffstat/,/^$/p' <<<"$out" | grep '|')"
out=$(ctx "$tmp/stack" --rev main..feat/b)
check "context: range - parent" "main" "$(key parent <<<"$out")"
check "context: range - tip" "feat/b" "$(key tip <<<"$out")"
check "context: range - report-prefix" "main..feat/b" "$(key report-prefix <<<"$out")"
check "context: range - diff-command" "git diff main...feat/b" "$(key diff-command <<<"$out")"
check "context: range - commits" "2" "$(sed -n '/^## Commits/,/^$/p' <<<"$out" | grep -c '^[0-9a-f]\{7,\} ')"
out=$(ctx "$tmp/stack" --rev feat/a...)
check "context: range - three dots, empty tip" "git diff feat/a...HEAD" "$(key diff-command <<<"$out")"
ctx "$tmp/stack" --rev main..main >/dev/null; code=$?
check "context: range - empty exits 1" 1 "$code"
check "context: range - empty message" "No diff in 'main..main' — nothing to review." "$(cat "$tmp/stderr")"
ctx "$tmp/stack" --rev "$(git -C "$tmp/stack" rev-list --max-parents=0 HEAD)" >/dev/null; code=$?
check "context: rev - root commit exits 1" 1 "$code"
ctx "$tmp/stack" --rev nope >/dev/null; code=$?
check "context: rev - missing ref exits 1" 1 "$code"
check "context: rev - missing ref message" "Ref 'nope' not found." "$(cat "$tmp/stderr")"
ctx "$tmp/stack" --rev main..feat/b main >/dev/null; code=$?
check "context: rev - parent override exits 1" 1 "$code"

# --- docs-index.sh ---

new_repo "$tmp/nodocs"
git -C "$tmp/nodocs" rm -q README.md && git -C "$tmp/nodocs" commit -q -m rm
commit_file "$tmp/nodocs" src/a.kt "fun a() = 1"
check "docs: none" "docs-found: 0" "$(cd "$tmp/nodocs" && "$skill/docs-index.sh")"

new_repo "$tmp/docs"
mkdir -p "$tmp/docs/build" "$tmp/docs/sub" "$tmp/docs/docs/adr"
printf '# Guide\n\ntext\n\n## Naming\n\n### Deep\n' >"$tmp/docs/docs/guide.md"
printf 'build/\n' >"$tmp/docs/.gitignore"
printf '# Ignored\n' >"$tmp/docs/build/notes.md"
printf '# Sub readme\n' >"$tmp/docs/sub/README.md"
printf '# Rules\n' >"$tmp/docs/sub/CLAUDE.md"
printf '# Contributing\n' >"$tmp/docs/CONTRIBUTING.md"
printf '# ADR 1\n' >"$tmp/docs/docs/adr/0001.md"
printf 'png' >"$tmp/docs/docs/diagram.png"
git -C "$tmp/docs" add -A && git -C "$tmp/docs" commit -q -m docs
printf '# Untracked\n' >"$tmp/docs/docs/draft.md"
check "docs: index" "docs-found: 5
file: CONTRIBUTING.md
  # Contributing
file: README.md
  # R
file: docs/adr/0001.md
  # ADR 1
file: docs/guide.md
  # Guide
  ## Naming
  ### Deep
file: sub/CLAUDE.md
  # Rules" "$(cd "$tmp/docs" && "$skill/docs-index.sh")"

# --- review-report-path.sh ---

new_repo "$tmp/My Repo"
git -C "$tmp/My Repo" switch -q -c feat/Some_Thing
GIT_AUTHOR_NAME="Józef Mąka" commit_file "$tmp/My Repo" a.txt a
GIT_AUTHOR_NAME="Józef Mąka" commit_file "$tmp/My Repo" b.txt b
commit_file "$tmp/My Repo" c.txt c
dir="$HOME/.ai/my-repo/reviews"
check "path: slugs, diacritics, majority author" "$dir/$today-feat-some-thing-jozef-maka.md" \
  "$(cd "$tmp/My Repo" && "$bin/review-report-path.sh" main)"
check "path: creates the reviews dir" "yes" "$([ -d "$dir" ] && echo yes || echo no)"
check "path: prefix" "$dir/$today-mr-42-feat-some-thing-jozef-maka.md" \
  "$(cd "$tmp/My Repo" && "$bin/review-report-path.sh" main "MR 42")"

check "path: log range" "$dir/$today-feat-some-thing-test-dev.md" \
  "$(cd "$tmp/My Repo" && "$bin/review-report-path.sh" HEAD~1..HEAD)"
check "path: no commits falls back to the current user" "$dir/$today-uncommitted-feat-some-thing-test-dev.md" \
  "$(cd "$tmp/My Repo" && "$bin/review-report-path.sh" HEAD uncommitted)"

git -C "$tmp/My Repo" worktree add -q "$tmp/wt-folder" -b feat/wt main
commit_file "$tmp/wt-folder" w.txt w
check "path: worktree uses the main repo name" "$dir/$today-feat-wt-test-dev.md" \
  "$(cd "$tmp/wt-folder" && "$bin/review-report-path.sh" main)"

git clone -q --bare "$tmp/My Repo" "$tmp/bare/proj.git"
git -C "$tmp/bare/proj.git" worktree add -q "$tmp/bare-wt" -b feat/bare main
commit_file "$tmp/bare-wt" x.txt x
check "path: worktree of a bare repo uses the repo name" \
  "$HOME/.ai/proj/reviews/$today-feat-bare-test-dev.md" \
  "$(cd "$tmp/bare-wt" && "$bin/review-report-path.sh" main)"

exit "$fail"
