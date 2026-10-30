# Watch: GitLab

The host file for GitLab. Run each command in the repo of the watched MRs. `watchd` is the client
of the watch daemon, on PATH.

| Function                              | Command                                                                                        |
| ------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Watch command, hub mode               | `watchd watch --session <id> --interval 120`                                                   |
| Watch command, author mode            | `watchd watch --session <id> --interval 120` in the worktree of the MRs                        |
| Watch command, review mode            | `watchd watch --session <id> --review --fresh --mr <iid> --interval 120`                       |
| Unsubscribe                           | `watchd unsubscribe --session <id>`, with the `--review` and `--mr` flags of the watch command |
| Daemon status                         | `watchd status`                                                                                |
| Router result                         | `watchd route --iid <iid> --action <bump\|review\|none>`                                       |
| Report                                | `printf '%s' '<json>' \| watchd report <flags of the watch command>`                           |
| MR details: branches, author, labels  | `~/.config/agents/bin/fetch-gitlab-mr.sh resolve <url>`                                        |
| Logs of the failed jobs of a pipeline | `~/.config/agents/bin/gitlab-pipeline.sh failed-logs <pipeline id>`                            |
| Retry a job                           | `glab ci retry <job id>`                                                                       |
| Retry a job and wait for the new job  | `~/.config/agents/skills/hub/hub-retry.sh <job id>`                                            |

- `<id>` is the session ID. The runner file tells how to get it.
- `--fresh` deletes the state of an earlier review watch of the MR. Use it only at the first start.
- The author mode watch gets the events of all MRs of the worktree. With one `--mr <iid>` for each
  MR, it gets only the events of these MRs.
- Report: the JSON goes in single quotes. Replace each `'` in the JSON text with a space.
- The id of an MR is `!<iid>`.
- If the stderr text of exit `1` names a token permission, tell the user to add that permission to
  the fine-grained token of `glab`.
- The events of each mode are in the doc comment of `~/.config/agents/daemon/src/engine/mod.rs`.
