- Sidebar: the `feature-b` workspace shows the conflict token.
- `watchd debug state` in the repo: the worktree state of `repo-stack` has `README.md` in
  `conflict`.
- `watchd.log`: a line `fast-forward: main`, because the main checkout has no local commits.
