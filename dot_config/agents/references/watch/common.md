# Watch: common rules

A watch is a background task that checks the code host. It stops at the first check with events.
You handle the events, report, and start the watch again. Between events, the user can use the session for
other work.

The text uses GitLab words: MR, pipeline, job. On GitHub, the same rules apply to PRs and checks.

## Files

Read this file, the host file, and the role file that the skill names. All files are in
`~/.config/agents/references/watch/`.

- Host file: the commands of the code host. Select it from the host of the `origin` remote:
  `gitlab.md` for GitLab. If the prompt or a wrapper skill names a different host file, use that
  file. If no host file agrees with the host, do not start the watch. Tell it in one line.
- Role file: the events of the role, and the action for each event.

| Role file     | Skill       | Watches                                                        |
| ------------- | ----------- | -------------------------------------------------------------- |
| `hub.md`      | `hub`       | The project: to-do items, new MRs, comments, default branch    |
| `author.md`   | `draft-pr`  | The MRs of the stack of the user                               |
| `reviewer.md` | `review-pr` | One MR of a different person, for its reviewer                 |
| `bump.md`     | `bump`      | One dependency bump MR                                         |

## Task

- The watch is a background Bash task (`run_in_background: true`). Use the watch command of the
  host file for the role.
- A session has one watch task. If a watch task runs, do not start a new one. If it watches a
  different MR, tell it in one line.
- If the user says "watch", start the watch. If the user says "stop watch", stop the task.
- The watch pauses during system sleep. During a network outage, it waits for the network with no
  report.

## Result

| Exit | Action                                                                                 |
| ---- | -------------------------------------------------------------------------------------- |
| `0`  | Handle the events and report, as the role file tells. Then start the watch again.      |
| `1`  | Report the stderr text and send a notification. Do not start again. See the host file. |
| `3`  | A new watch replaced this one. Do not start again. No notification.                    |

On exit `0`, the output has one JSON line for each event: `kind`, `iid`, `title`, `url`,
`actor`, `detail`, and `branch`. The role file tells the other fields of its events.

Start the watch again with the restart command of the host file. If all watched MRs are merged or
closed, do not start it again. Tell it in one line.

## MR events

This part is for the roles that watch MRs: `author.md`, `reviewer.md`, and `bump.md`.

- A comment, an own comment, a reaction, a resolved thread, or an `unaddressed` thread on a diff
  line also has `path` and `line`.
- A `merged` or `closed` event that the user did has `own: true`.
- The watch gives no events for the other actions of the user, except `own-comment`.
- A `comment` and an `unaddressed` line with the same `url` are one item.

These event kinds have the same action in each role. The table of the role file has only the
other kinds.

| `kind`             | Action                         | Report section    |
| ------------------ | ------------------------------ | ----------------- |
| `own-comment`      | See "Own comments"             | Info or Needs you |
| `unaddressed`      | The thread waits for the user  | Needs you         |
| `merged`, `closed` | Do not start the watch again   | Info              |
| all other kinds    | None                           | Info              |

The user does these actions, never you: reply to a comment, resolve a thread, react, approve,
merge, close, mark an MR ready, or change its title, description, or labels.

### Own comments

An `own-comment` event is a comment or a reply of the user. Make sure that it is correct:

1. Read the full comment and its thread. The `detail` has only the first 100 characters.
2. If the comment has a `path`, read the code at `path:line` at the MR head.
3. Compare the statements of the comment with the code, the diff, and the thread.

Result:

- The comment is correct and clear: one line under Info: `Your comment on <path:line> is OK.`
- A statement is wrong, or the comment refers to the wrong code: put it under Needs you, with the
  error and a short proposed change.
- Small points only, for example an unclear word: one item under Info, with the points.

Do not rewrite the full comment. The user edits it on the code host.

### Report

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

### Notification

If `HERDR_ENV` is `1`, send one notification for each report. Replace each `'` in the text with a
space.

```sh
herdr notification show '<title>' --body '<body>' --sound <sound>
```

- Title: `!<iid>: <n> needs you`. If Needs you is empty, `!<iid>`. For more MRs: `<n> MRs`.
- Body: the most urgent item in one line, then the Done items. Example:
  `@anna asked on NoteEditor.kt:42. Pipeline fixed and pushed.`
- Sound: if there are new Needs you items, `request`. Else `none`.
- If all events of the result are `own-comment` events with no Needs you item, or events with
  `own: true`, send no notification.
