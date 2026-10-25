#!/usr/bin/env bash
# Usage: review-report-path.sh <parent-ref | log-range> [prefix]
# Prints the absolute path of the review report file,
# ~/.ai/<repo>/reviews/<date>-[<prefix>-]<branch>-<author>.md, and creates its parent dir.
# The author is the majority author of the range (<parent-ref>..HEAD), or the current user when
# the range has no commits.
# Exit codes: 0 ok, 1 no range argument.
set -euo pipefail

range="${1:?parent ref or log range required}"
[[ "$range" == *..* ]] || range="$range..HEAD"
prefix="${2:-}"

# shellcheck source=git-lib.sh
source "$(dirname "$0")/git-lib.sh"

repo_slug="$("$(dirname "$0")/repo-slug.sh")"

branch="$(git rev-parse --abbrev-ref HEAD)"
branch_slug="$(slugify "${branch//\//-}")"

author="$(git shortlog -sn "$range" | head -1 | sed -E 's/^ *[0-9]+\t//')"
[ -n "$author" ] || author="$(git var GIT_AUTHOR_IDENT | sed 's/ <.*//')"
author_slug="$(slugify "$author")"

date_prefix="$(date +%F)"

dir="$HOME/.ai/$repo_slug/reviews"
mkdir -p "$dir"
if [ -n "$prefix" ]; then
  printf '%s/%s-%s-%s-%s.md\n' "$dir" "$date_prefix" "$(slugify "$prefix")" "$branch_slug" "$author_slug"
else
  printf '%s/%s-%s-%s.md\n' "$dir" "$date_prefix" "$branch_slug" "$author_slug"
fi
