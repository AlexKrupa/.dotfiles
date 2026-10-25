#!/usr/bin/env bash
# Usage: git-absorb-fixes.sh <parent> <file>...
# Folds applied fixes into the commits that added the changed lines.
# <parent> is the parent ref/SHA review-diff resolved (its report's `parent:` line).
# <file>... are ONLY the files the skill modified this pass (never the whole tree).
#
# Pipeline:
#   1. Stage exactly the given files (never `git add -A`).
#   2. `git absorb --base <parent>` - auto-fixups every hunk it can blame to one commit.
#   3. For each file absorb left staged (orphan), blame the changed lines, pick the
#      dominant in-range commit, and `git commit --fixup=<sha> -- <file>`.
#   4. Files whose dominant blame SHA is outside <parent>..HEAD (or pure additions with
#      nothing to blame) are LEFT STAGED and reported as `needs-message`. The caller
#      writes a conventional message and commits them.
#
# Emits a keyed text block on stdout for the caller's summary: absorb-fixups, blame-fixups
# (`<sha> <file>` lines), needs-message, staged-remaining. Makes no other git writes
# (no push/rebase/amend/reset). Changes outside the given files stay unstaged and uncommitted.
# Aborts (exit 1) on: no files, git-absorb missing, not a repo, bad parent, HEAD == parent,
# a non-empty index (pre-staged work must not go into the fixups), or a missing file.
set -euo pipefail

die() { printf 'git-absorb-fixes: %s\n' "$1" >&2; exit 1; }
# shellcheck source=git-lib.sh
source "$(dirname "$0")/git-lib.sh"

[ "$#" -ge 2 ] || die "Usage: git-absorb-fixes.sh <parent> <file>..."
parent="$1"; shift
files=("$@")

command -v git-absorb >/dev/null 2>&1 || die "git-absorb not installed."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git work tree."
git rev-parse --verify --quiet "$parent" >/dev/null || die "Parent ref '$parent' not found."

parent_sha="$(git rev-parse "$parent")"
[ "$parent_sha" != "$(git rev-parse HEAD)" ] || die "HEAD == parent; nothing to absorb into."

if [ -n "$(git diff --cached --name-only)" ]; then
  die "Index not empty before staging - refusing to mix in pre-staged changes."
fi
for f in "${files[@]}"; do
  [ -e "$f" ] || git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 \
    || die "File not found and not tracked: $f"
done

git add -- "${files[@]}"

if [ -z "$(git diff --cached --name-only)" ]; then
  printf 'absorb-fixups: 0\nblame-fixups: 0\nneeds-message: 0\nstaged-remaining: no\n'
  exit 0
fi

before="$(git rev-list --count "$parent_sha"..HEAD)"
git absorb --base "$parent" >/dev/null 2>&1 || true
after="$(git rev-list --count "$parent_sha"..HEAD)"
absorb_fixups=$(( after - before ))

# Blames the old lines of the staged hunks. Prints the most frequent SHA in <parent>..HEAD, or
# nothing.
dominant_sha() {
  local file="$1" hunks sha
  # --no-ext-diff: an external diff tool (for example difftastic) prints no @@ headers.
  hunks="$(git --no-pager diff --no-ext-diff --cached -U0 -- "$file" \
    | sed -n 's/^@@ -\([0-9]*\),\{0,1\}\([0-9]*\) .*/\1 \2/p')"
  {
    while read -r a b; do
      [ -n "$a" ] || continue
      b="${b:-1}"; [ "$b" -gt 0 ] 2>/dev/null || continue   # pure additions: nothing to blame
      git blame --porcelain -L "$a,+$b" HEAD -- "$file" 2>/dev/null \
        | grep -Eo '^[0-9a-f]{40} ' || true
    done <<< "$hunks"
  } | tr -d ' ' | grep -v '^0\{40\}$' \
    | sort | uniq -c | sort -rn | while read -r _ sha; do
        if in_range "$parent_sha" "$sha"; then
          printf '%s\n' "$sha"; break
        fi
      done
  return 0   # a no-match pipeline returns nonzero - that is normal (-> needs-message)
}

blame_fixups=()    # "<sha7> <file>"
needs_message=()   # "<file>"

# The files that git absorb did not place.
while IFS= read -r file; do
  [ -n "$file" ] || continue
  sha="$(dominant_sha "$file")"
  if [ -n "$sha" ]; then
    git commit --fixup="$sha" -- "$file" >/dev/null
    blame_fixups+=("$(git rev-parse --short "$sha") $file")
  else
    needs_message+=("$file")   # leave staged for the caller to commit with a message
  fi
done < <(git diff --cached --name-only)

printf 'absorb-fixups: %d\n' "$absorb_fixups"
printf 'blame-fixups: %d\n' "${#blame_fixups[@]}"
for e in "${blame_fixups[@]:-}"; do [ -n "$e" ] && printf '  %s\n' "$e"; done
printf 'needs-message: %d\n' "${#needs_message[@]}"
for f in "${needs_message[@]:-}"; do [ -n "$f" ] && printf '  %s\n' "$f"; done
printf 'staged-remaining: %s\n' "$([ "${#needs_message[@]}" -gt 0 ] && echo yes || echo no)"
