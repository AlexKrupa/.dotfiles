#!/usr/bin/env bash
# Checks the deterministic review-branch helpers: git-branch-context.sh, docs-index.sh,
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
ctx() { (cd "$1" && shift && "$bin/git-branch-context.sh" "$@" 2>"$tmp/stderr"); }
key() { sed -n "s/^$1: //p"; }

# --- git-branch-context.sh ---

mkdir -p "$tmp/plain"
(cd "$tmp/plain" && "$bin/git-branch-context.sh" >/dev/null 2>"$tmp/stderr"); code=$?
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
