# The worktree goes away, and its workspace closes.
agent close branch
git -C "$repo" worktree remove --force "$SAMPLE_ROOT/repo-branch"
