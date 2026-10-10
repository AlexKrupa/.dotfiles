#!/usr/bin/env bash
# Usage: pr-path.sh
# Prints the paths of the PR draft for the current branch, one `key=value` per line:
#   file=~/.ai/<repo>/prs/<branch-slug>.md
#   media=~/.ai/<repo>/prs/<branch-slug>
# Creates ~/.ai/<repo>/prs/. Does not create the media dir, because most drafts have no media.
set -euo pipefail

branch="$(git branch --show-current)"
[ -n "$branch" ] || { echo "pr-path.sh: no current branch (detached HEAD)" >&2; exit 1; }

slug="$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's#[^a-z0-9]+#-#g; s#^-+##; s#-+$##')"

dir="$HOME/.ai/$("$(dirname "$0")/repo-slug.sh")/prs"
mkdir -p "$dir"
printf 'file=%s/%s.md\nmedia=%s/%s\n' "$dir" "$slug" "$dir" "$slug"
