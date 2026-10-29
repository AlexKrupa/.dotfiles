# watchd sample

`sample` moves a test daemon and a generated sample repo through fixed scenarios, one step at a
time. You see the `watchd` states live in the herdr sidebar, the board, and the agent panes, with
no GitLab and no Claude. The test daemon runs next to your real daemon and does not change it.

## How it works

- `sample start` builds `watchd` with the `test-support` feature and copies it to
  `~/.local/share/watchd-sample/bin/watchd`. The test daemon uses the fake engine
  (`src/engine/fake.rs`), the fake workspaces, and the fake `bin/git-spice`. Its state is in
  `~/.local/state/watchd-sample`.
- The sample repo is `~/.local/share/watchd-sample/repo`, with the bare repo `origin.git` as
  `origin`. Its git configuration key `watchd.stateHome` sends all clients in the repo and its
  worktrees to the test daemon.
- A second `watch.sh` watcher shows the sample workspaces in the herdr sidebar.
- An agent session is `agent-loop` in the root pane of the worktree workspace: one
  `watchd watch --session`, then `watchd wait --session` again and again.
- `SAMPLE_ROOT` and `SAMPLE_STATE` change the two base folders.

Requirements: herdr, cargo, jq, and bash 5. The script is `~/.config/agents/daemon/sample/sample`.

## Commands

```sh
sample start                 # build the test-support binary, start the test daemon and its herdr watcher
sample stop                  # stop the agent sessions, the watcher, and the test daemon
sample run <scenario> [<n>]  # reset, then apply the steps of the scenario up to step n (default 1)
sample next                  # apply the next step
sample back                  # replay from the reset to the step before
sample status                # scenario, step, expect list, daemon PID and binary
sample list                  # the scenarios and their steps, with a mark on the current step
sample ui                    # the control pane: all steps, keys n next, p back, r reset, step number and Enter, q quit
sample check [<scenario>]    # run the scenarios with no herdr and look for daemon errors
```

A reset stops the agent sessions and closes their workspaces. Then it stops the test daemon,
deletes its state and the sample repo, makes the repo again, and starts the daemon.

## Scenarios

Each step is a folder `scenarios/<scenario>/NN-<step>/`:

- `step.sh`: the change from the step before, with the helpers of `lib.sh`.
- `expect.md`: what you see in the sidebar, the board, and the agent panes.
- `errors` (optional): the patterns of the error lines that `sample check` expects.

| Scenario | Steps |
| --- | --- |
| `hub` | `clean`, `hub-pipeline-failed`, `pull-blocked` |
| `branch` | `branch-open`, `branch-watching`, `branch-events`, `branch-merged`, `worktree-removed` |
| `stack` | `stack-open`, `stack-conflict`, `stack-bottom-merged`, `stack-no-agent` |
| `review` | `review-open`, `review-update` |
| `errors` | `own-mr`, `check-error`, `hub-retry` |
| `daemon` | `restart`, `migration` |

`sample check` compares no sidebar. You do that by eye with `expect.md`. The tests are
`sample.test.sh`.
