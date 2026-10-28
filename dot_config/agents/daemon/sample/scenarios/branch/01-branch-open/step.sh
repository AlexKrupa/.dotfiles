# One branch in a worktree with one MR. The workspace opens, but no agent session watches.
git -C "$repo" worktree add -q -b feature "$SAMPLE_ROOT/repo-branch"
commit "$SAMPLE_ROOT/repo-branch" feature.txt "Add feature"
spice "$SAMPLE_ROOT/repo-branch" '{"name": "main", "ups": [{"name": "feature"}]}
{"name": "feature", "current": true, "down": {"name": "main"}, "change": {"id": "!5"}}'
(cd "$SAMPLE_ROOT/repo-branch" && "$watchd" kind mine)
agent open branch
