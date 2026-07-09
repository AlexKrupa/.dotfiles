#!/usr/bin/env bash
# Print the docs directory for the current location.
# All linked worktrees of one repo resolve to the same directory.
# Outside a git repo: prints ~/.ai/_no-repo/docs.
# Repo-name resolution lives in the shared repo-slug.sh primitive.
set -e

repo=$(bash "$HOME/.config/ai/bin/repo-slug.sh")
printf '%s\n' "$HOME/.ai/$repo/docs"
