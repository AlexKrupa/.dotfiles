# Watch: GitLab

The host file for GitLab. Run each command in the repo of the watched MRs. `$W` is
`~/.config/agents/bin/watch/watch.sh`, the client of the watch daemon.

| Function                                  | Command                                                         |
| ----------------------------------------- | --------------------------------------------------------------- |
| Watch command, hub mode                   | `$W --interval 120`                                             |
| Watch command, stack mode                 | `$W --interval 120 --mr <iid>`, with one `--mr` for each MR     |
| Watch command, review mode                | `$W --review --fresh --mr <iid> --interval 120`                 |
| Restart command                           | The same watch command, with no `--fresh`                       |
| Unsubscribe                               | `$W unsubscribe`, with the `--review` and `--mr` flags of the watch command |
| Daemon status                             | `$W status`                                                     |
| Router result                             | `$W route --iid <iid> --action <bump\|review\|none>`            |
| Report                                    | `printf '%s' '<json>' \| $W report <flags of the watch command>` |
| MR details: branches, author, labels      | `~/.config/agents/bin/fetch-gitlab-mr.sh resolve <url>`         |
| Logs of the failed jobs of a pipeline     | `~/.config/agents/bin/gitlab-pipeline.sh failed-logs <pipeline id>` |
| Retry a job                               | `glab ci retry <job id>`                                        |
| Retry a job and wait for the new job      | `~/.claude/skills/hub/hub-retry.sh <job id>`                    |

- `--fresh` deletes the state of an earlier review watch of the MR. Use it only at the first start.
- Report: the JSON goes in single quotes. Replace each `'` in the JSON text with a space.
- The id of an MR is `!<iid>`.
- If the stderr text of exit `1` names a token permission, tell the user to add that permission to
  the fine-grained token of `glab`.
- The events of each mode are in the header comment of `watch-gitlab.sh`.
