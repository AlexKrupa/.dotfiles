# Watch: bump

The role file of `bump`: the review mode for one dependency bump MR. A bot owns the branch. You own
the fixes for the bump and the verdict. The steps below are the steps of `bump`.

## Start

In the bump worktree, run the review mode watch command for the MR.

## Events

Handle a `pushed` event first. Then the other events read the new code.

| `kind`             | Action                  | Report section    |
| ------------------ | ----------------------- | ----------------- |
| `pushed`           | See "Pushes"            | Done or Needs you |
| `pipeline`, failed | See "Pipeline failures" | Done or Needs you |
| `pipeline`, passed | Update the verdict      | Info              |
| `comment`          | See "Comments"          | Needs you         |

Do not wait for CI with `bump-host.sh ci --wait` during the watch. The next `pipeline` event gives
the result.

If the verdict changes, put the new verdict under Info. If it is `needs you`, put it under Needs
you.

## Pushes

If `new_head` is a commit that you pushed, do nothing more.

1. Run `git fetch <remote> <branch>`.
2. Find your fix commits that are not in the new head: their subjects are not in
   `git log --format=%s <new_base>..<new_head>`. Put each lost fix commit under Needs you, with
   its SHA and subject. Do not push it again.
3. If the working tree is clean, run `git reset --keep <remote>/<branch>`. Else, put "local branch
   behind the MR, working tree not clean" under Needs you.
4. Compare the dependency versions in `git diff <old_base> <old_head>` and
   `git diff <new_base> <new_head>`.
   - The versions changed: do steps 3 to 5 again for the new versions. Write a new report. Put
     the new changes and issues that affect the repo under Needs you.
   - The versions are the same: put "Rebased, same versions." under Info.

## Pipeline failures

Do steps 6 and 7 again for the new pipeline:

- A job failed for a cause that the bump did not make: retry it once with `bump-host.sh retry`.
  If the same job fails again after a retry, put it under Needs you.
- A failure that the bump caused: commit the fix and push it, as step 7 tells. Report it under
  Done.

## Comments

Read the code at `path:line` at the MR head, and the thread. Assess the comment and propose an
answer. Put it under Needs you. Do not change the code until the user asks.
