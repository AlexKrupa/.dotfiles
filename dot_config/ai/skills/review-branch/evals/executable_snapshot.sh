#!/usr/bin/env bash
# Usage: snapshot.sh <repo-dir>
# Prints the repo state that review-branch must not change: refs, HEAD, worktree status,
# stash, and a hash of every non-ignored file. Diff a before and an after snapshot.
set -euo pipefail
cd "$1"
echo "HEAD: $(git symbolic-ref -q HEAD || true) $(git rev-parse HEAD)"
git for-each-ref --format='%(refname) %(objectname)'
echo "status:"
git status --porcelain --untracked-files=all
echo "stash: $(git stash list | wc -l | tr -d ' ')"
echo "files:"
git ls-files -co --exclude-standard -z | xargs -0 shasum
