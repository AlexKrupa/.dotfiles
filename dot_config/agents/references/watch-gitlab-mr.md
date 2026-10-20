# watch-gitlab-mr

The agent guide for the MR modes of `~/.config/agents/bin/watch-gitlab.sh`: the stack mode (`--mr`)
of `draft-pr`, and the review mode (`--review --mr`) of `review-pr`. The skill tells the mode
and the action for each event kind.

The text uses GitLab words: MR, pipeline, job. On GitHub, the same rules apply to PRs and checks.

## Task

The watch is a background Bash task (`run_in_background: true`). Each 120 seconds, it checks the
MRs. If it finds events, it stops. Then you handle the events, report, and start it again. Between
events, the user can use the session for other work. The watch pauses during system sleep. During
a network outage, it waits for the network with no report.

- Give the command `--interval 120`.
- If a watch task runs, do not start a new one.
- If the user says "watch", start the watch. If the user says "stop watch", stop the task.

## Result

| Exit | Action                                                                  |
| ---- | ----------------------------------------------------------------------- |
| `0`  | Handle the events, report, and start again as the skill tells.          |
| `1`  | Report the stderr text and send a notification. Do not start again.     |
| `3`  | A new watch replaced this one. Do not start again. No notification.     |

On exit `0`, the output has one JSON line for each event: `kind`, `iid`, `title`, `url`,
`actor`, `detail`, and `branch`. A comment, a reaction, a resolved thread, or an `unaddressed`
thread on a diff line also has `path` and `line`. A `pushed` event also has `old_base`,
`old_head`, `new_base`, and `new_head`.

A `comment` and an `unaddressed` line with the same `url` are one item.

## Report

One block for each report. One group for each MR, in stack order from the bottom. Omit an empty
section.

```text
14:32 !123 Fix crash on rotation
https://gitlab.example.com/app/-/merge_requests/123

Needs you
1. @anna on NoteEditor.kt:42: "Why not rememberSaveable here?"
   Valid. rememberSaveable also keeps the text after process death.
   Proposed fix: replace the SavedStateHandle field (3 lines).

Done
- Pipeline 4567: ktlint failed in 2 files. Formatted, folded into abc1234, pushed.

Info
- @bob approved.
- @carol reacted :thumbsup: to your comment on NoteEditor.kt:42.
```

- Needs you shows all open items, also the items from earlier reports. If the result shows that
  an item is addressed, the item leaves the list. Examples: the thread is not in `unaddressed`, or
  a new pipeline passed. Number the items. The user can then say "fix 1".
- Done shows the actions that you did for the events of this result.
- Info shows the other events of this result.

## Notification

If `HERDR_ENV` is `1`, send one notification for each report. Replace each `'` in the text with a
space.

```sh
herdr notification show '<title>' --body '<body>' --sound <sound>
```

- Title: `!<iid>: <n> needs you`. If Needs you is empty, `!<iid>`. For more MRs: `<n> MRs`.
- Body: the most urgent item in one line, then the Done items. Example:
  `@anna asked on NoteEditor.kt:42. Pipeline fixed and pushed.`
- Sound: if there are new Needs you items, `request`. Else `none`.
