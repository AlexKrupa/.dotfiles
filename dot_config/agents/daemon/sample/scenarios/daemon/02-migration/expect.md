- `watchd.log`: a new `daemon start` line with a new PID, and no `record removed` line.
- `watchd debug state` in the repo: the worktree state of `repo-branch` has the kind `mine` from
  the version 1 file.
- The worktree state file of `repo-branch` has `"version": 4` after the new commit. The files
  that did not change keep `"version": 1`.
