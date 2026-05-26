#!/usr/bin/env bash
# Usage: report-path.sh <parent-ref>
# Prints absolute path to the review report file under
# ~/.ai/reviews/<repo>/<author>-<branch>.md and ensures the parent dir exists.
set -euo pipefail

parent="${1:?parent ref required}"

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#[^a-z0-9]+#-#g; s#^-+##; s#-+$##'
}

# --git-common-dir with absolute path resolves to the main repo's .git even
# inside a linked worktree, so all worktrees of one repo share one directory.
common_git="$(git rev-parse --path-format=absolute --git-common-dir)"
repo_root="$(cd "$common_git/.." && pwd)"
repo_slug="$(slugify "$(basename "$repo_root")")"

branch="$(git rev-parse --abbrev-ref HEAD)"
branch_slug="$(slugify "${branch//\//-}")"

author="$(git shortlog -sn "$parent..HEAD" | head -1 | sed -E 's/^ *[0-9]+\t//')"
author_slug="$(slugify "$author")"

dir="$HOME/.ai/reviews/$repo_slug"
mkdir -p "$dir"
printf '%s/%s-%s.md\n' "$dir" "$author_slug" "$branch_slug"
