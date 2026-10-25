#!/usr/bin/env bash
# Usage: repo-slug.sh
# Prints the ~/.ai/ subdirectory name for the current location.
# All linked worktrees of one repo resolve to the same name.
# Outside a git repo: prints `_no-repo`.
# Writes nothing. Exit codes: 0 ok.
set -euo pipefail

# shellcheck source=git-lib.sh
source "$(dirname "$0")/git-lib.sh"

common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)

if [ -z "$common_dir" ]; then
  printf '%s\n' "_no-repo"
  exit 0
fi

# Regular repo:  /foo/repo/.git    -> repo
# Linked worktree resolves to main repo's .git via --git-common-dir.
# Bare repo:     /foo/repo.git     -> repo
# Submodule:     /super/.git/modules/<name> -> <name>
case "$common_dir" in
  */.git)
    repo=$(basename "$(dirname "$common_dir")")
    ;;
  *.git)
    repo=$(basename "${common_dir%.git}")
    ;;
  */.git/modules/*)
    repo=$(basename "$common_dir")
    ;;
  *)
    repo=$(basename "$common_dir")
    ;;
esac

printf '%s\n' "$(slugify "$repo")"
