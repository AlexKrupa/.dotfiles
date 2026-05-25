#!/usr/bin/env bash
# Find the active design doc for the current location.
#
# Usage:
#   find-active-doc.sh           # auto-detect
#   find-active-doc.sh <name>    # substring match on filename or title
#
# Output: absolute path of active doc, or empty. Exit 0 always.
# An "active" doc has `status: active` in its frontmatter.
# Subdirs starting with `_` are ignored.
set -e

script_dir=$(cd "$(dirname "$0")" && pwd)
docs_dir=$(bash "$script_dir/docs-dir.sh" 2>/dev/null || true)
[ -z "$docs_dir" ] || [ ! -d "$docs_dir" ] && exit 0

is_active() {
  # $1 = file path. Returns 0 if frontmatter has `status: active`.
  [ -f "$1" ] || return 1
  awk '
    /^---[[:space:]]*$/ { fm++; if (fm == 2) exit }
    fm == 1 && /^status:[[:space:]]*active[[:space:]]*$/ { print "y"; exit }
  ' "$1" | grep -q y
}

list_top_level_docs() {
  # Non-recursive scan, skip _* dirs (we are already non-recursive but
  # find -maxdepth 1 + -not -path keeps it explicit).
  find "$docs_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort
}

match_substring() {
  # $1 = needle. Look at filenames and `title:` frontmatter.
  needle=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for f in $(list_top_level_docs); do
    base=$(basename "$f" .md | tr '[:upper:]' '[:lower:]')
    if [[ "$base" == *"$needle"* ]]; then
      printf '%s\n' "$f"
      continue
    fi
    title=$(awk '/^title:/ { sub(/^title:[[:space:]]*/, ""); print tolower($0); exit }' "$f")
    if [[ "$title" == *"$needle"* ]]; then
      printf '%s\n' "$f"
    fi
  done
}

if [ -n "${1:-}" ]; then
  # Named lookup: return any active match; prefer exact filename hit.
  exact="$docs_dir/$1.md"
  if [ -f "$exact" ] && is_active "$exact"; then
    printf '%s\n' "$exact"
    exit 0
  fi
  for f in $(match_substring "$1"); do
    if is_active "$f"; then
      printf '%s\n' "$f"
      exit 0
    fi
  done
  exit 0
fi

# Auto-detect.
branch=$(git branch --show-current 2>/dev/null || true)
if [ -n "$branch" ]; then
  candidate="$docs_dir/$branch.md"
  if [ -f "$candidate" ] && is_active "$candidate"; then
    printf '%s\n' "$candidate"
    exit 0
  fi
fi

# Fallback: single active doc wins. Multiple -> empty (caller asks user).
active=""
count=0
for f in $(list_top_level_docs); do
  if is_active "$f"; then
    active="$f"
    count=$((count + 1))
  fi
done
if [ "$count" = "1" ]; then
  printf '%s\n' "$active"
fi
exit 0
