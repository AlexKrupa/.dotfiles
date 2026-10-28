# A stack of two branches in one worktree, MRs 3 and 4, and a watching agent session.
git -C "$repo" worktree add -q -b feature-a "$SAMPLE_ROOT/repo-stack"
commit "$SAMPLE_ROOT/repo-stack" a.txt "Add part A"
git -C "$SAMPLE_ROOT/repo-stack" switch -q -c feature-b
commit "$SAMPLE_ROOT/repo-stack" b.txt "Add part B"
spice "$SAMPLE_ROOT/repo-stack" '{"name": "main", "ups": [{"name": "feature-a"}]}
{"name": "feature-a", "down": {"name": "main"}, "ups": [{"name": "feature-b"}], "change": {"id": "!3"}}
{"name": "feature-b", "current": true, "down": {"name": "feature-a"}, "change": {"id": "!4"}}'
(cd "$SAMPLE_ROOT/repo-stack" && "$watchd" kind mine)
agent start stack
