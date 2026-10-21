# Watch: author

The role file of `draft-pr`: the stack mode for the MRs of the stack of the user. You fix small
failures. During the watch, only trivial fixes are pushed.

## Idle session

If these three conditions are true, the session is idle:

- the working tree is clean
- no rebase or merge is in progress
- you are not in the middle of a different task

If the session is not idle, do not do an auto-fix.

## Start

1. Run `git-spice log short --all=false --json --no-prompt`. For each branch object with `change`,
   take `change.id`. A branch with no `change` has no MR yet.
2. If there is no MR, tell it in one line and stop.
3. Run the stack mode watch command with each MR.

After you handle the events, do "Start" again with the current list, not the restart command. A
sync can delete a merged branch, and the user can add a branch.

## Events

| `kind`             | Action                  | Report section       |
| ------------------ | ----------------------- | -------------------- |
| `pipeline`, failed | See "Pipeline failures" | Done or Needs you    |
| `conflict`         | See "Conflicts"         | Done or Needs you    |
| `merged`           | See "Merged MRs"        | Info, Done/Needs you |
| `comment`          | See "Comments"          | Needs you            |

Needs you also shows the failures that wait for the user, and the fixes that wait.

## Pipeline failures

Run the host command for the logs of the failed jobs. Find the cause of each failed job.

- The cause is outside the branch: a runner or system failure, the network, a cache, or a service
  that is down. Retry the job with the host command. A retry needs no idle session.
- The cause is a formatter or lint error, or an obvious compile error, in the code of the branch.
  If the session is idle, fix it:
  1. Switch to the branch of the MR. Remember the branch that was current.
  2. Make the fix.
  3. Run `~/.config/agents/bin/git-diff-context.sh --parent-only` and get `parent`.
  4. Run `~/.config/agents/bin/git-absorb-fixes.sh <parent> <file>...` with the changed files. If it
     reports a file under `needs-message`, the fix is not trivial. Undo it with
     `git restore --staged --worktree -- <file>...` and put the failure under Needs you.
  5. Run `~/.config/agents/bin/git-squash-fixups.sh "$(git merge-base <parent> HEAD)"`.
  6. Do "Push".
  7. Switch back to the branch that was current.

  If the session is not idle, put the failure under Needs you as "fix waits, session not idle",
  with the proposed fix. If the session is idle at the next report, or if the user asks, do the fix.
- All other causes: if the session is idle and the cause is clear, do the fix with steps 1 to 7
  above. In step 4, commit each `needs-message` file with a one-line message. Report the fix under
  Done. Else put the failure under Needs you, with the cause and a proposed fix.

## Push

Each push of the watch also syncs and restacks the stack. The push starts a new pipeline anyway,
so the pipeline then tests the newest base.

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

## Comments

Read the code at `path:line` and the thread. Then assess the comment:

- A suggestion: is it good? Why or why not?
- A reported bug: is it real?
- A question: propose an answer.

Put the assessment and a proposed fix or answer under Needs you. Do not change the code until the
user asks.

If an `own-comment` is a review comment of the PR draft file, do not check it. You wrote it.
