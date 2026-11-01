- `watchd.log`: a new `daemon start` line with a new PID, and `format 1 not supported, record
  removed` lines for the version 1 files.
- `watchd debug state` in the repo: the worktree state of `repo-branch` has no kind `mine`. The
  daemon did not convert the version 1 file.
