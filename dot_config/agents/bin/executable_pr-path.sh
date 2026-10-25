#!/usr/bin/env bash
# Usage: pr-path.sh
# Prints the paths of the PR draft for the current branch, one `key: value` per line:
#   file: ~/.ai/<repo>/prs/<branch-slug>.md
#   media: ~/.ai/<repo>/prs/<branch-slug>
# Creates ~/.ai/<repo>/prs/. Does not create the media dir, because most drafts have no media.
# Exit codes: 0 ok, 1 no current branch (detached HEAD).
set -euo pipefail

branch="$(git branch --show-current)"
[ -n "$branch" ] || { echo "pr-path.sh: no current branch (detached HEAD)" >&2; exit 1; }

# shellcheck source=git-lib.sh
source "$(dirname "$0")/git-lib.sh"
slug="$(slugify "$branch")"

dir="$HOME/.ai/$("$(dirname "$0")/repo-slug.sh")/prs"
mkdir -p "$dir"
printf 'file: %s/%s.md\nmedia: %s/%s\n' "$dir" "$slug" "$dir" "$slug"
