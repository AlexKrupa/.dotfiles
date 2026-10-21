# Watch: reviewer

The role file of `review-pr`: the review mode for one MR of a different person. The hard
constraints of `review-pr` apply during the watch: no writes to the code host, and no commits or
pushes.

The last reviewed head is `reviewed_head` of `review-pr`, or the `new_head` of the last push that
you reviewed.

## Start

1. In `clone`, run the review mode watch command.
2. Run `git fetch <remote> <source_branch> <target_branch>`. If
   `git rev-parse <remote>/<source_branch>` is not the last reviewed head, the author pushed during
   the review. Handle it as a `pushed` event with these values:
   - `old_base`: `git merge-base <target_ref> <last reviewed head>`
   - `old_head`: the last reviewed head
   - `new_base`: `git merge-base <target_ref> <remote>/<source_branch>`
   - `new_head`: `<remote>/<source_branch>`

## Events

Handle a `pushed` event first. Then the other events read the new code.

| `kind`        | Action                                                                           | Report section        |
| ------------- | -------------------------------------------------------------------------------- | --------------------- |
| `pushed`      | See "Pushes"                                                                     | Needs you, Done, Info |
| `comment`     | See "Comments"                                                                   | Needs you or Info     |
| `resolved`    | See "Resolved threads"                                                           | Info or Needs you     |
| `description` | Read the new description. If the purpose of the MR changed, propose a new review | Needs you or Info     |

## Pushes

1. Run `git fetch <remote> <source_branch> <target_branch>`. Do not use `"$FMR" fetch`. After a
   force push, it stops. The local branch does not move.
2. Run `~/.config/agents/bin/git-interdiff.sh <old_base> <old_head> <new_base> <new_head>`.
   - If it exits `1` with `unknown commit`, the old version is not in the local repo. Put it under
     Needs you, and propose a full review of the MR. Stop here.
   - If the output is empty, put "Rebased, no content change." under Info. Stop here.
3. Review only the lines of the output. Read the files at `new_head` with
   `git show <new_head>:<path>`, because the working tree has the old version. Use the severity
   rules and the finding format of `review-diff`. Do not use `review-diff` for the full MR again.
4. Add a section to the end of the report: `## Update <date> <first 8 characters of new_head>`.
   It has the findings that the push fixed, the new findings, and the findings that stay open.
5. Under Needs you: one item for each new finding. Under Done: "Reviewed push <short new_head>,
   report updated." Under Info: the findings that the push fixed.
6. If the local branch is not at `new_head`, add under Info: "The local branch is behind the MR.
   The review read the files at <short new_head>."

## Comments

Read the code at `path:line` at the MR head, and the thread.

- A reply in a thread that the user started or replied in: assess the reply. Does it answer the
  point of the user? Propose a response. Put it under Needs you.
- A different comment about the code of a finding, or against the review: give your assessment
  and the id of the finding. Put it under Needs you.
- All other comments: one line under Info.

## Resolved threads

Run `git diff <reviewed_head> <remote>/<source_branch> -- <path>`. Then compare the change with
the point of the thread. Use `reviewed_head`, not the last reviewed head: the fix can be in a push
that you reviewed.

- The change fixes the point: one line under Info.
- There is no change, or the change does not fix the point: put "resolved with no fix" under
  Needs you, with the point of the thread.
