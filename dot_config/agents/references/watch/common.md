# Watch: common rules

A watch is a background task that checks the code host. It stops at the first check with events.
You handle the events, report, and start the watch again. Between events, the user can use the
session for other work.

The text uses GitLab words: MR, pipeline, job. On GitHub, the same rules apply to PRs and checks.

Name an MR by its title. Put `!<iid>` only after the title, never alone.

## Files

Read this file, the host file, and the role file that the skill names. All files are in
`~/.config/agents/references/watch/`.

- Host file: the commands of the code host. Select it from the host of the `origin` remote:
  `gitlab.md` for GitLab. If the prompt or a wrapper skill names a different host file, use that
  file. If no host file agrees with the host, do not start the watch. Tell it in one line.
- Role file: the events of the role, and the action for each event.

| Role file     | Skill       | Watches                                                     |
| ------------- | ----------- | ----------------------------------------------------------- |
| `hub.md`      | `hub`       | The project: to-do items, new MRs, comments, default branch |
| `author.md`   | `draft-pr`  | The MRs of the stack of the user                            |
| `reviewer.md` | `review-pr` | One MR of a different person, for its reviewer              |
| `bump.md`     | `bump`      | One dependency bump MR                                      |

## Task

- The watch is a background Bash task (`run_in_background: true`). Use the watch command of the
  host file for the role.
- A session has one watch task. If a watch task runs, do not start a new one. If it watches a
  different MR, tell it in one line.
- If the user says "watch", start the watch. If the user says "stop watch", stop the task. Then run
  the unsubscribe command of the host file.
- The watch pauses during system sleep. During a network outage, it waits for the network with no
  report.
- The `watch` herdr plugin sends all notifications of the watch. Do not send a notification.

## Result

| Exit | Action                                                                                 |
| ---- | -------------------------------------------------------------------------------------- |
| `0`  | Handle the events and report, as the role file tells. Then start the watch again.      |
| `1`  | Report the stderr text. Do not start again. See the host file.                         |
| `3`  | A new watch replaced this one. Do not start again.                                     |

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
- Each event has `row`: the number of its row in the report. A `comment` and an `unaddressed`
  line of one thread have the same `row`: they are one item.
- The review mode also gives `pushed` and `resolved` events. A `pushed` event is a change of the
  head, with `old_base`, `old_head`, `new_base`, and `new_head`. A `resolved` event is a thread
  that the user started and a different user resolved. Its `unaddressed` lines are only for the
  threads that have a comment of the user.

These event kinds have the same action in each role, unless the role file has a row for the
kind. The watch gives no event for a change of the user. The full event list with the exceptions
is in the doc comment of `~/.config/agents/daemon/src/engine/mod.rs`.

| `kind`             | Action                        | Report section    |
| ------------------ | ----------------------------- | ----------------- |
| `own-comment`      | See "Own comments"            | Info or Needs you |
| `unaddressed`      | The thread waits for the user | Needs you         |
| `title`, `labels`  | None                          | Info              |
| `description`      | None                          | Info              |
| `merged`, `closed` | Do not start the watch again  | Info              |
| all other kinds    | None                          | Info              |

The user does these actions, never you: reply to a comment, resolve a thread, react, approve,
merge, close, mark an MR ready, or change its title, description, or labels.

### Own comments

An `own-comment` event is a comment or a reply of the user. Make sure that it is correct:

1. Read the full comment and its thread. The `detail` has only the first 100 characters.
2. If the comment has a `path`, read the code at `path:line` at the MR head.
3. Compare the statements of the comment with the code, the diff, and the thread.

Result:

- The comment is correct and clear: the cell of its row is `OK`.
- A statement is wrong, or the comment refers to the wrong code: put its row in `close`, and add
  a `needs` row with the error and a short proposed change.
- Small points only, for example an unclear word: the cell of its row has the points.

Do not rewrite the full comment. The user edits it on the code host.

### Report

Run the host command "Report" with the JSON of your actions. Output its stdout word for word. It
prints one table for each MR, in the order of the `--mr` flags. With no `--mr` flags, it prints one
table for each MR of the watch, in the order of the MR numbers. The JSON fields, all optional:

- `cells`: your text for each row, for example `{"2": "Valid. Fix: replace the field"}`. An open
  item keeps its text for the next reports.
- `agent`: the rows of the events that you handled. An open item in it closes.
- `close`: the rows that need nothing more. An open item in it closes. A thread that is still
  in `unaddressed` opens again at the next round with events.
- `add`: a row with no event, as `{"section": "needs", "iid": <iid>, "what": "<text>",
  "result": "<text>"}`. The section `needs` opens an item that stays until you close it.
  Examples: a lost fix commit, "fix waits, session not idle", a new review finding.

The sections:

- Needs you shows all open items, also the items from earlier reports. The watch closes an item
  when GitLab shows that its cause is gone. Examples: the thread is not in `unaddressed`, or a new
  pipeline passed. An item keeps its number, so the user can say "fix 1".
- Agent shows the actions that you did for the events of this result.
- Info shows the other events of this result.
