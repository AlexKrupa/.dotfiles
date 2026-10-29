- Sidebar: the `feature-b` workspace still shows the conflict token, for `README.md` only.
- Agent pane: the `merged` event line of MR 3. Then the loop runs `watchd wait` again.
- `watchd debug state` in the repo: the worktree state of `repo-stack` has MR 3 in `ended`,
  `feature-a` in `ended_branches`, and only `README.md` in `conflict`.
