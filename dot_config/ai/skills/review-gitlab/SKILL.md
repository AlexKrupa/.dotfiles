---
name: review-gitlab
description:
  Review of a GitLab merge request - by URL, MR id, branch, or the current branch. Adds MR context
  (description, discussions, labels, bot findings) to the branch audit. Read-only.
argument-hint: "[mr-url | mr-id | branch | <empty>]"
disable-model-invocation: true
---

# review-gitlab

This skill adds GitLab merge request context to `review-diff`. It has the same read-only
constraints. The output is one Markdown report at
`~/.ai/<repo>/reviews/<date>-mr-<iid>-<branch>-<author>.md`. After the reply, it watches the MR in
the background (see "Watch").

An empty argument means "the MR of the current branch". Outside the MR's repo, only a URL works.

## REQUIRED SUB-SKILL

Use `review-diff` for the audit and the report. Give it the `target_ref` from `fetch` as the
parent override (see "Parent override" in `review-diff`). `target_ref` is the fresh
`<remote>/<target>` remote-tracking ref. Do not use the local `target_branch`, because it can be
out of date. Do not do again what `review-diff` does: git discovery, severity buckets, and the
finding format. After it writes the report, add the MR context to that file (see "Report").

## Helper scripts

The shared script `fetch-gitlab-mr.sh` does all GitLab fetches and JSON parsing. Run it with
`--help` for its usage. The working directory is not the skill directory. Always run the script by
its absolute path. Shell variables do not persist between Bash calls. Start each command that uses
`$FMR` with the binding:

```sh
FMR=~/.config/ai/bin/fetch-gitlab-mr.sh
```

In the workflow, `$iid`, `$clone`, and the other values from script output are the literal
values. Write them into each later command.

Do not do again inline what the script does. Subcommands:

- `"$FMR" preflight` - runs the prerequisite checks in fail-fast order: `glab` and `jq` are
  installed, and `glab` is authenticated. Prints `ok`, or stops
  with one line and a non-zero exit code.
- `"$FMR" resolve "<input>"` - the input is an MR, pipeline, or job URL, a numeric iid, a branch
  name, or empty (the current branch). JSON: `iid`, `project_path`, `source_branch`,
  `target_branch`, `web_url`, `state`, `draft`, `labels`, `author`, `pipeline_status`,
  `description`.
- `"$FMR" locate <project>` - prints the local clone of `project`: the current repo if its remote
  matches, else the one match below `~/src`.
- `"$FMR" fetch <source> <target> [project]` - run it in the clone. It fast-forwards the local
  `<source>` to the MR tip with no checkout. It keeps unpushed local commits and stops on
  divergence. It updates `refs/remotes/<remote>/<target>` and does not write the local `<target>`.
  If there is more than one remote, it uses the remote whose URL matches `project`. JSON: `remote`,
  `source_branch`, `target_branch`, `target_ref` (`<remote>/<target>`).
- `"$FMR" discussions <iid> [project]` - a JSON array of normalized threads. The script removes the
  threads that have only system notes. Fields: `id`, `individual_note`, `resolvable`, `resolved`,
  `note_count`, `authors`, `first_body` (at most 280 characters), `files`.
- `"$FMR" diff-check <iid> [target]` - exits `0` if the files in the local `target...HEAD` are the
  same as the files of the MR. Else exits `1` with the file difference on stderr. Give the resolved
  `target_branch` to prevent one more `glab mr view` call.

Exit codes: `0` ok, `1` usage or parse error, `2` not found, `3` ambiguous, `4` a missing tool,
or missing auth, `5` network. Exit `3` means more than one open MR for the branch,
or more than one clone. The script prints the candidates on stderr. Show them to the user and ask
the user to select one. On all other non-zero exit codes, stop with one line. Do not retry.

`GITLAB_API_TOKEN` is not a prerequisite. If the token exists, the API fallback of the script uses
it.

`pipeline_status` is `"n/a"` when the MR has no head pipeline, for example a draft or a new push.
This is not an error.

## Workflow

1. Run `"$FMR" preflight`. If the exit code is not `0`, show the line and stop.
2. `"$FMR" resolve "<input>"` - get `iid`, `source_branch`, `target_branch`, `project_path`, and
   the other fields from the JSON.
3. `"$FMR" locate "$project_path"` - the output is `clone`.
4. Run `git -C "$clone" branch --show-current`. If the output is not `source_branch`, stop. Tell
   the user the current branch and the MR branch, and give the options. For example: switch to
   the MR branch, or stash the changes first if the working tree is dirty. Do not do one of them
   until the user selects it.
5. `cd "$clone" && "$FMR" fetch "$source_branch" "$target_branch" "$project_path"` - get
   `target_ref` (for example `origin/main`) from the JSON. Get `reviewed_head` with
   `git rev-parse HEAD`.
   If the session working directory is not `clone`, start each later Bash command with
   `cd "$clone" &&`, and give file tools absolute paths below `clone`.
6. Get the report path with the `mr-<iid>` prefix (see "Report"). Use `review-diff` with
   `$target_ref` as the parent override, and tell it to write the report to that path. Do not
   rename the file after. Read the report before you add to it.
7. `"$FMR" discussions "$iid" "$project_path"` - select the threads for the report (see
   "Discussion filtering").
8. Optional: `"$FMR" diff-check "$iid" "$target_branch"`. If it exits `1`, write the difference in
   the report.
9. Add the MR context to the report (see "Report").
10. Reply as `review-diff` "Final reply" tells.
11. Start the watch (see "Watch").

## Discussion filtering

The script removed the threads that have only GitLab system notes (label and assignee changes,
pipeline status messages, WIP changes). Put a thread in the report if one of these is true:

- `note_count >= 2`
- `resolvable == true && resolved == false`
- `files` has a file that an audit finding names

Else, do not put it in the report. For a bot thread (`authors` has the SAST, coverage, or CI bot),
put it in the report only if `first_body` names a specific file or function, or has a real failure
message. Do not include status messages. Write one line for each thread. Do not copy full bodies.

## Report

Path: `~/.ai/<repo>/reviews/<date>-mr-<iid>-<branch>-<author>.md`. Get it from the
`review-report-path.sh` helper with `mr-<iid>` as the prefix. Do not make the slug yourself:

```sh
path="$(~/.config/ai/bin/review-report-path.sh "$target_ref" "mr-<iid>")"
```

`<author>` is the **majority git commit author** from the helper, not the GitLab MR user name. The
helper makes the repo, author, and branch slugs and removes diacritics. If the file exists,
overwrite it.

Add to the base report:

1. **Header** - add the MR URL, target branch, labels, state, draft flag, and pipeline status.
2. **Context** (new, between the header and Review guide):
   - Write the MR description in one paragraph. If it is empty, write "no description provided".
   - Coverage check: compare the description with the changes in the diff. Write what the
     description does not tell.
3. **Findings** (from the base report) - if a finding matches a discussion or a bot note, add
   `(see thread by @<reviewer>)` or `(SAST flagged this)` after the finding id.
4. **Discussions** (new, after Findings):
   - One bullet for each selected thread: the reviewer, the main point, the resolution state, and
     your opinion if the thread is not resolved or does not agree with the audit. Give the id of
     the related finding if there is one.
   - One bullet for each selected bot finding.
5. **Out of scope / mentions** - no change from the base report.

## Watch

The watch reports the events of the MR that are important to a reviewer. The hard constraints of
this skill apply during the watch.

Read `~/.config/ai/references/watch-gitlab-mr.md` first. It tells how to run the watch task,
handle its exit codes, report, and send notifications. This section tells only the reviewer
actions.

The last reviewed head is `reviewed_head`, or the `new_head` of the last push that you reviewed.

### Start

1. If a watch task for a different MR runs in this session, tell it in one line and stop. This
   skill watches one MR in each session.
2. In `clone`, run `~/.config/ai/bin/watch-gitlab.sh --review --mr <iid> --interval 120`, as the
   reference tells.
3. Run `git fetch <remote> <source_branch> <target_branch>`. If
   `git rev-parse <remote>/<source_branch>` is not the last reviewed head, the author pushed during
   the review. Handle it as a `pushed` event with these values:
   - `old_base`: `git merge-base <target_ref> <last reviewed head>`
   - `old_head`: the last reviewed head
   - `new_base`: `git merge-base <target_ref> <remote>/<source_branch>`
   - `new_head`: `<remote>/<source_branch>`

### Events

Handle a `pushed` event first. Then the other events read the new code.

| `kind`               | Action                         | Report section          |
| -------------------- | ------------------------------ | ----------------------- |
| `pushed`             | See "Pushes"                   | Needs you, Done, Info   |
| `comment`            | See "Comments"                 | Needs you or Info       |
| `unaddressed`        | The thread waits for the user  | Needs you               |
| `resolved`           | See "Resolved threads"         | Info or Needs you       |
| `merged`, `closed`   | Do not start the watch again   | Info                    |
| all other kinds      | None                           | Info                    |

After you handle the events, start the watch again for the same MR. If the MR is merged or closed,
do not start it again. Tell it in one line.

### Pushes

1. Run `git fetch <remote> <source_branch> <target_branch>`. Do not use `"$FMR" fetch`. After a
   force push, it stops. The local branch does not move.
2. Run `~/.config/ai/bin/git-interdiff.sh <old_base> <old_head> <new_base> <new_head>`.
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

### Comments

Read the code at `path:line` at the MR head, and the thread.

- A reply in a thread that the user started or replied in: assess the reply. Does it answer the
  point of the user? Propose a response. Put it under Needs you.
- A different comment about the code of a finding, or against the review: give your assessment
  and the id of the finding. Put it under Needs you.
- All other comments: one line under Info.

The user writes all responses on GitLab. Do not post them.

### Resolved threads

Run `git diff <last reviewed head> <remote>/<source_branch> -- <path>`. Then compare the change
with the point of the thread.

- The change fixes the point: one line under Info.
- There is no change, or the change does not fix the point: put "resolved with no fix" under
  Needs you, with the point of the thread.

## Hard constraints

All constraints of `review-diff`, and also:

- No `glab mr approve`, `glab mr note --message`/`-m`, `glab mr update`, `glab mr merge`,
  `glab mr close`, `glab mr revoke`, or other write subcommands.
- No API `POST`, `PUT`, or `DELETE`.
- No `git push`, commits, amends, or rebases.
- Branch changes occur only through `"$FMR" fetch` (fast-forward only), or after the user
  selects an option in workflow step 4. During the watch, `git fetch` changes only the
  remote-tracking refs, and the local branch does not move.
- No job retries, replies, or reactions during the watch.

## Red flags - stop and think again

- You are about to use `review-diff` without the MR's `target_ref` as the parent override. The
  default parent detection selects the nearest local ancestor branch. For stacked MRs, the
  findings are then wrong.
- You are about to call `glab mr` with `-m`, `--message`, `approve`, `merge`, `update`, or
  `note create`. This skill is read-only.
- You copy full discussion text into the report. Write a summary.
- You review while the MR branch is not checked out, because "the diff is sufficient".
  `review-diff` needs the working tree to examine the files, not only the diff hunks.
- You are about to run `git switch`, `git checkout`, or `git stash` before the user selects that
  option.
- There is more than one open MR for the branch, and you selected one without a question. Ask the
  user.
- You call `glab mr view`, `glab api .../discussions`, or `glab mr list` directly, not through
  `$FMR`. The script defines the JSON format. Direct calls give a different format.
- After a push, you are about to use `review-diff` for the full MR. Review only the output of
  `git-interdiff.sh`.
- After a force push, you are about to use `"$FMR" fetch`. It stops on divergence. Use
  `git fetch`.
