#!/usr/bin/env bash
# Usage: absorb-fixes.sh <parent> <file>...
# Folds already-applied fixes into the commits that introduced them, deterministically.
# <parent> is the parent ref/SHA review-branch resolved (its report's `parent:` line).
# <file>... are ONLY the files the skill modified this pass (never the whole tree).
#
# Pipeline:
#   1. Stage exactly the given files (never `git add -A`).
#   2. `git absorb --base <parent>` — auto-fixups every hunk it can blame to one commit.
#   3. For each file absorb left staged (orphan), blame the changed lines, pick the
#      dominant in-range commit, and `git commit --fixup=<sha> -- <file>`.
#   4. Files whose dominant blame SHA is outside <parent>..HEAD (or pure additions with
#      nothing to blame) are LEFT STAGED and reported as `needs-message` — the caller
#      writes a conventional message and commits them. The script never invents messages.
#
# Emits a keyed text block on stdout for the caller's summary. Makes no other git writes
# (no push/rebase/amend/reset). Aborts (exit 1) on: not a repo; bad parent; no files; dirty
# tree containing changes outside the given files (would risk staging unrelated work).
set -euo pipefail

die() { printf '%s\n' "$1" >&2; exit 1; }

[ "$#" -ge 2 ] || die "Usage: absorb-fixes.sh <parent> <file>..."
parent="$1"; shift
files=("$@")

command -v git-absorb >/dev/null 2>&1 || die "git-absorb not installed."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git work tree."
git rev-parse --verify --quiet "$parent" >/dev/null || die "Parent ref '$parent' not found."

parent_sha="$(git rev-parse "$parent")"
[ "$parent_sha" != "$(git rev-parse HEAD)" ] || die "HEAD == parent; nothing to absorb into."

# Guard: every given file must exist and be one we can stage. Refuse if the index already
# holds staged content (caller's loop must reach here with a clean index aside from our adds).
if [ -n "$(git diff --cached --name-only)" ]; then
  die "Index not empty before staging — refusing to mix in pre-staged changes."
fi
for f in "${files[@]}"; do
  [ -e "$f" ] || git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 \
    || die "File not found and not tracked: $f"
done

git add -- "${files[@]}"

# Nothing staged after add (e.g. files identical to HEAD) -> no-op.
if [ -z "$(git diff --cached --name-only)" ]; then
  printf 'absorb-fixups: 0\nblame-fixups: 0\nneeds-message: 0\nstaged-remaining: no\n'
  exit 0
fi

before="$(git rev-list --count "$parent_sha"..HEAD)"
git absorb --base "$parent" >/dev/null 2>&1 || true
after="$(git rev-list --count "$parent_sha"..HEAD)"
absorb_fixups=$(( after - before ))

# Dominant in-range blame SHA for a file's staged changes, or empty if none qualifies.
# Blames the OLD (pre-change) line ranges from the staged diff against HEAD, tallies SHAs,
# keeps the most frequent one that lies strictly within <parent>..HEAD.
dominant_sha() {
  local file="$1" hunks sha
  # Old-side ranges "@@ -a,b" from the staged diff (HEAD vs index).
  # --no-ext-diff/--no-pager: a configured external differ (e.g. difftastic) emits no
  # @@ headers, which would silently break hunk parsing.
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
        # In range: descendant of parent, ancestor of HEAD, not parent itself.
        if [ "$sha" != "$parent_sha" ] \
          && git merge-base --is-ancestor "$parent_sha" "$sha" 2>/dev/null \
          && git merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
          printf '%s\n' "$sha"; break
        fi
      done
  return 0   # a no-match pipeline returns nonzero; that is normal (-> needs-message)
}

blame_fixups=()    # "<sha7> <file>"
needs_message=()   # "<file>"

# Orphans: files absorb could not place. Resolve one at a time.
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
