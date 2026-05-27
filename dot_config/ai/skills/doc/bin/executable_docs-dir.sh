#!/usr/bin/env bash
# Print the docs directory for the current location.
# All linked worktrees of one repo resolve to the same directory.
# Outside a git repo: prints ~/.ai/_no-repo/docs.
set -e

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#[^a-z0-9]+#-#g; s#^-+##; s#-+$##'
}

common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)

if [ -z "$common_dir" ]; then
  printf '%s\n' "$HOME/.ai/_no-repo/docs"
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

repo=$(slugify "$repo")
printf '%s\n' "$HOME/.ai/$repo/docs"
