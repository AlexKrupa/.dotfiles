#!/usr/bin/env bash
# Usage: docs-index.sh
# Discovers project documentation / convention files (tracked only) and prints a cheap
# path+headings index on stdout for review-branch's docs-alignment check. Read-only,
# deterministic, side-effect-free. Selection of which listed docs are relevant is the
# caller's (model's) judgment — this script only discovers and indexes.
#
# Output:
#   docs-found: <N>
#   file: <relative-path>
#     <heading line>            (markdown ATX headings, verbatim, 2-space indent)
#   ...
# N == 0 prints only the count line. Over-size files print "  (large, headings omitted)".
# Once the total heading budget is spent, remaining files list H1 lines only.
set -euo pipefail

PER_FILE_MAX=102400   # bytes; skip heading extraction above this
INDEX_MAX=16384       # bytes; total heading budget before H1-only fallback

die() { printf '%s\n' "$1" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "Not inside a git work tree — nothing to index."

root="$(git rev-parse --show-toplevel)"
cd "$root"

# Classify a tracked path; echo it if it is a doc/convention/agent file, else nothing.
classify() {
  local p="$1" base="${1##*/}" lower
  lower="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
  case "$p" in
    docs/*|documentation/*|doc/*)
      case "$lower" in *.md|*.markdown|*.rst) printf '%s\n' "$p"; return;; esac ;;
  esac
  case "$p" in
    docs/adr/*) printf '%s\n' "$p"; return ;;
  esac
  # root-level convention files (no slash in path)
  case "$p" in
    */*) : ;;
    *)
      case "$base" in
        CONTRIBUTING*|contributing*|README*|readme*|Readme*|ARCHITECTURE*|architecture*|STYLE*|style*|Style*)
          printf '%s\n' "$p"; return ;;
      esac ;;
  esac
  # agent instruction files, any location
  case "$base" in
    CLAUDE.md|AGENTS.md|GEMINI.md|.cursorrules) printf '%s\n' "$p"; return ;;
  esac
}

# Collect matches (dedupe + sort).
mapfile -t files < <(
  git ls-files -z \
  | while IFS= read -r -d '' p; do classify "$p"; done \
  | LC_ALL=C sort -u
)

printf 'docs-found: %s\n' "${#files[@]}"
[ "${#files[@]}" -eq 0 ] && exit 0

budget="$INDEX_MAX"
for f in "${files[@]}"; do
  printf 'file: %s\n' "$f"
  # size guard
  size="$(wc -c < "$f" 2>/dev/null || echo 0)"
  if [ "$size" -gt "$PER_FILE_MAX" ]; then
    printf '  (large, headings omitted)\n'
    continue
  fi
  if [ "$budget" -gt 0 ]; then
    headings="$(grep -E '^#{1,6} ' -- "$f" 2>/dev/null || true)"
  else
    headings="$(grep -E '^# ' -- "$f" 2>/dev/null || true)"   # over budget: H1 only
  fi
  [ -n "$headings" ] || continue
  while IFS= read -r h; do
    printf '  %s\n' "$h"
  done <<< "$headings"
  budget=$(( budget - ${#headings} ))
done
