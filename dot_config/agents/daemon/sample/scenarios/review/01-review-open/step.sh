origin_commit review-7 r.txt "Add part R"
git -C "$repo" fetch -q origin
git -C "$repo" worktree add -q -b review-7 "$SAMPLE_ROOT/repo-review" origin/review-7
(cd "$SAMPLE_ROOT/repo-review" && "$watchd" kind review)
agent start review
