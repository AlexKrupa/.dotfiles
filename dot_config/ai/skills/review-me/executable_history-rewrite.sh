#!/usr/bin/env bash
# Usage: history-rewrite.sh [--dry-run] <parent> <source>:<target>...
# Squashes over-fragmented commits into the commits they belong to, deterministically.
# <parent> is the parent ref/SHA review-branch resolved (its report's `parent:` line).
# Each spec means: commit <source> is a repair of commit <target>. Fold source into target.
# <source> must be NEWER than <target>. Both must lie strictly within <parent>..HEAD.
#
# Pipeline:
#   1. Validate: clean tree, no rebase in progress, no merge commits in range, every spec
#      in range and correctly ordered, no commit used as both source and target.
#   2. Save a backup ref so the pre-rewrite branch is always recoverable.
#   3. `git rebase -i --autosquash <parent>` with this script as GIT_SEQUENCE_EDITOR.
#      --autosquash places any pending fixup!/amend! commits. The editor pass then moves
#      each <source> line to sit right after its <target> block and marks it `fixup`.
#      Reordering therefore happens as part of the same rewrite, not as a separate step.
#   4. On any conflict or failure: `git rebase --abort`, reset back to the backup, exit 1.
#      The script never leaves a half-rebased branch and never resolves a conflict itself.
#
# Emits a keyed text block on stdout for the caller's summary. Makes no other git writes
# (no push, no remote change, no commit outside the rebase).
set -euo pipefail

die() { printf '%s\n' "$1" >&2; exit 1; }

# ---- GIT_SEQUENCE_EDITOR mode -------------------------------------------------------
# Re-entry: the parent process re-execs this script as the rebase todo editor.
# $REVIEW_ME_SPECS holds one "<full-source-sha> <full-target-sha>" pair per line.
if [ "${1:-}" = "--edit-todo" ]; then
  todo="$2"
  mapfile -t lines < "$todo"

  # Index of the todo line whose sha matches $1 (todo shas are abbreviated). -1 if absent.
  find_line() {
    local want="$1" i cmd sha
    for i in "${!lines[@]}"; do
      read -r cmd sha _ <<< "${lines[$i]}"
      case "$cmd" in pick|p|reword|r|edit|e|squash|s|fixup|f) ;; *) continue ;; esac
      [ -n "$sha" ] || continue
      case "$want" in "$sha"*) printf '%s\n' "$i"; return 0 ;; esac
    done
    printf '%s\n' "-1"
  }

  declare -A placed=()   # per target: how many sources we already inserted after it
  while read -r src tgt; do
    [ -n "$src" ] || continue
    si="$(find_line "$src")"; ti="$(find_line "$tgt")"
    [ "$si" -ge 0 ] || die "Source commit ${src:0:7} not in rebase todo."
    [ "$ti" -ge 0 ] || die "Target commit ${tgt:0:7} not in rebase todo."

    line="${lines[$si]}"
    read -r _ sha rest <<< "$line"
    unset 'lines[si]'; lines=("${lines[@]}")            # remove, then recompact
    [ "$si" -lt "$ti" ] && ti=$((ti - 1))               # target shifted left

    # Insert directly after the target, ahead of any fixup!/amend! lines --autosquash
    # already attached. Those were written against the current tip and must stay last.
    # Multiple sources for one target keep their original order.
    at=$((ti + 1 + ${placed[$tgt]:-0}))
    placed[$tgt]=$(( ${placed[$tgt]:-0} + 1 ))

    new=("${lines[@]:0:$at}" "fixup $sha $rest" "${lines[@]:$at}")
    lines=("${new[@]}")
  done <<< "${REVIEW_ME_SPECS:-}"

  printf '%s\n' "${lines[@]}" > "$todo"
  exit 0
fi

# ---- normal mode --------------------------------------------------------------------
dry_run=no
[ "${1:-}" = "--dry-run" ] && { dry_run=yes; shift; }

[ "$#" -ge 2 ] || die "Usage: history-rewrite.sh [--dry-run] <parent> <source>:<target>..."
parent="$1"; shift

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git work tree."
git rev-parse --verify --quiet "$parent" >/dev/null || die "Parent ref '$parent' not found."
[ -z "$(git status --porcelain)" ] || die "Working tree not clean. Commit or stash first."
for d in rebase-merge rebase-apply; do
  [ -e "$(git rev-parse --git-path "$d")" ] && die "A rebase is already in progress."
done

parent_sha="$(git rev-parse "$parent")"
head_sha="$(git rev-parse HEAD)"
[ "$parent_sha" != "$head_sha" ] || die "HEAD == parent; no branch commits to rewrite."
[ -z "$(git rev-list --merges "$parent_sha"..HEAD)" ] \
  || die "Range contains merge commits; refusing to flatten history."

# Resolve and validate every spec before touching anything.
in_range() {
  local sha="$1"
  [ "$sha" != "$parent_sha" ] \
    && git merge-base --is-ancestor "$parent_sha" "$sha" 2>/dev/null \
    && git merge-base --is-ancestor "$sha" HEAD 2>/dev/null
}

specs=""; sources=""; targets=""
for spec in "$@"; do
  case "$spec" in *:*) ;; *) die "Bad spec '$spec'; expected <source>:<target>." ;; esac
  src="$(git rev-parse --verify --quiet "${spec%%:*}^{commit}")" \
    || die "Source commit '${spec%%:*}' not found."
  tgt="$(git rev-parse --verify --quiet "${spec##*:}^{commit}")" \
    || die "Target commit '${spec##*:}' not found."
  [ "$src" != "$tgt" ] || die "Spec '$spec' squashes a commit into itself."
  in_range "$src" || die "Source ${src:0:7} is outside $parent..HEAD."
  in_range "$tgt" || die "Target ${tgt:0:7} is outside $parent..HEAD."
  git merge-base --is-ancestor "$tgt" "$src" \
    || die "Target ${tgt:0:7} is not an ancestor of source ${src:0:7}; specs read <newer>:<older>."
  case "$sources" in *"$src"*) die "Commit ${src:0:7} given as source twice." ;; esac
  case "$targets" in *"$src"*) die "Commit ${src:0:7} is both a source and a target." ;; esac
  case "$sources" in *"$tgt"*) die "Commit ${tgt:0:7} is both a source and a target." ;; esac
  sources="$sources $src"; targets="$targets $tgt"
  specs="$specs$src $tgt
"
done

before="$(git rev-list --count "$parent_sha"..HEAD)"

if [ "$dry_run" = yes ]; then
  printf 'dry-run: yes\ncommits-before: %d\nplanned-squashes: %d\n' "$before" "$#"
  while read -r src tgt; do
    [ -n "$src" ] || continue
    printf '  %s %s -> %s %s\n' \
      "$(git rev-parse --short "$src")" "$(git log -1 --format=%s "$src")" \
      "$(git rev-parse --short "$tgt")" "$(git log -1 --format=%s "$tgt")"
  done <<< "$specs"
  exit 0
fi

backup="refs/review-me/backup-$(date +%Y%m%d-%H%M%S)"
git update-ref "$backup" "$head_sha"

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if ! REVIEW_ME_SPECS="$specs" \
     GIT_SEQUENCE_EDITOR="'$self' --edit-todo" \
     GIT_EDITOR=true \
     git rebase -i --autosquash "$parent_sha" >/dev/null 2>&1; then
  git rebase --abort >/dev/null 2>&1 || true
  git reset --hard "$head_sha" >/dev/null 2>&1 || true
  die "Rebase failed (conflict or bad todo). Branch restored to $head_sha. Backup: $backup"
fi

after="$(git rev-list --count "$parent_sha"..HEAD)"
printf 'backup-ref: %s\n' "$backup"
printf 'squashes-applied: %d\n' "$#"
while read -r src tgt; do
  [ -n "$src" ] || continue
  printf '  %s -> %s\n' "${src:0:7}" "${tgt:0:7}"
done <<< "$specs"
printf 'commits-before: %d\ncommits-after: %d\nresult: ok\n' "$before" "$after"
