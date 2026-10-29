# feature-b and origin/main change the same line, so the stack conflicts with origin/main.
commit "$SAMPLE_ROOT/repo-stack" README.md "Stack change"
origin_commit main README.md "Main change"
