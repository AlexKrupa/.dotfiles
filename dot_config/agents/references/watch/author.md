# Watch: author

The role file of `draft-pr`: the author mode for the MRs of the worktree of the user. If the fix
of a failure is clear, you do it. A fix that needs a decision of the user waits under Needs you.

## Idle session

If these three conditions are true, the session is idle:

- the working tree is clean
- no rebase or merge is in progress
- you are not in the middle of a different task

If the session is not idle, do not do an auto-fix.

## MRs of other people

Do this check before any auto-fix, push, or restack push. "Push" restacks and pushes each branch
of the stack that has an MR. The check covers each of these MRs:

1. Run `git-spice log short --all=false --json --no-prompt`. For each branch object with `change`,
   take `change.url`.
2. Run the host command "User of the session".
3. For each URL, run the host command "Author of an MR" with the URL. Compare the name with the
   user.

If the author of one of these MRs is not the user, and that MR is not a bump MR, do not commit or
push. A bump MR is an MR of a bot: an author whose username has `renovate` or `dependabot`. Put the
fix under Needs you as a proposed fix, and name the MR of the other person. If the user tells you
to commit or push, do it.

## Start

1. Run `git-spice log short --all=false --json --no-prompt`. For each branch object with `change`,
   take `change.id`. A branch with no `change` has no MR yet.
2. If there is no MR, tell it in one line and stop.
3. Run the author mode watch command. It gets the events of all MRs of the worktree.

After you handle the events, do not do "Start" again. The watch continues, and it also gets the
events of an MR that the worktree gets later. If all MRs are merged or closed, `common.md` tells you
to run the unsubscribe command. This also covers a sync that deletes a merged branch.

## Events

| `kind`             | Action                  | Report section       |
| ------------------ | ----------------------- | -------------------- |
| `pipeline`, failed | See "Pipeline failures" | Agent or Needs you    |
| `conflict`         | See "Conflicts"         | Agent or Needs you    |
| `merged`           | See "Merged MRs"        | Info, Agent/Needs you |
| `comment`          | See "Comments"          | Needs you            |
| `pushed`           | See "Pushes"            | Needs you            |

Needs you also shows the failures that wait for the user, and the fixes that wait.

## Pipeline failures

Run the host command for the logs of the failed jobs. Find the cause of each failed job.

- The cause is outside the branch: a runner or system failure, the network, a cache, or a service
  that is down. Retry the job with the host command. A retry needs no idle session.
- The cause is in the code of the branch. If these four things are true, do the fix with steps 1
  to 7 below and report it under Agent:
  - the session is idle
  - the cause is clear
  - the fix is obvious
  - the fix needs no decision of the user

  A formatter error, a lint error, and an obvious compile error are cases of this rule. A behavior
  change, a change of a test expectation, or a large change needs a decision of the user. Put the
  failure under Needs you, with the cause and a proposed fix.

  1. Switch to the branch of the MR. Remember the branch that was current.
  2. Make the fix.
  3. Run `~/.config/agents/bin/git-diff-context.sh --parent-only` and get `parent`.
  4. Run `~/.config/agents/bin/git-absorb-fixes.sh <parent> <file>...` with the changed files.
     Commit each file that it reports under `needs-message` with a one-line message.
  5. Run `~/.config/agents/bin/git-squash-fixups.sh "$(git merge-base <parent> HEAD)"`.
  6. Do "Push".
  7. Switch back to the branch that was current.

  If the session is not idle, put the failure under Needs you as "fix waits, session not idle",
  with the proposed fix. If the session is idle at the next report, or if the user asks, do the fix.

## Push

Each push of the watch also syncs and restacks the stack. The push starts a new pipeline anyway,
so the pipeline then tests the newest base.

First do the check of "MRs of other people".

1. Run `git-spice repo sync --no-prompt` and `git-spice stack restack --no-prompt`.
2. On a conflict, do "Restack conflicts" of `draft-pr` step 2. It resolves a trivial conflict. If
   it aborts the restack or the validation fails, put the conflict or the failure under Needs you,
   with the files.
3. Run `git-spice stack submit --update-only --no-prompt`. After an aborted restack, this pushes
   the fix with no restack.

## Conflicts

If the session is not idle, put the conflict under Needs you as "fix waits, session not idle".
Else do "Push".

## Merged MRs

If no open MR of the stack is above the merged MR, do nothing more. If the session is not idle,
put the restack under Needs you as "fix waits, session not idle". Else do "Push".

## Pushes

A `pushed` event is a push that is not in the local branch of the MR and not in its reflog. An
example is a push from a different machine. Do not reset the branch, because it can have local
commits.

1. If `git cat-file -e <new_head>` fails, run `git fetch <remote> <source_branch>`.
2. If `git merge-base --is-ancestor <branch> <new_head>` exits 0, put under Needs you: "Someone
   pushed to the remote branch. The local branch is behind." Add the URL of the MR. Else write
   "diverged", not "behind".

## Comments

Read the code at `path:line` and the thread. Then assess the comment:

- A suggestion: is it good? Why or why not?
- A reported bug: is it real?
- A question: propose an answer.

Put the assessment and a proposed fix or answer under Needs you. Do not change the code until the
user asks.

If an `own-comment` is a review comment of the PR draft file, do not check it. You wrote it.
