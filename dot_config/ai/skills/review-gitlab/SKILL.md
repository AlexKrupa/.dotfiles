---
name: review-gitlab
description:
  Review of a GitLab merge request - by URL, MR id, branch, or the current branch. Adds MR context
  (description, discussions, labels, bot findings) to the branch audit. Opens the MR branch in a
  Herdr worktree workspace. Read-only.
argument-hint: "[mr-url | mr-id | branch | <empty>]"
disable-model-invocation: true
---

# review-gitlab

This skill adds GitLab merge request context to `review-branch`. It has the same read-only
constraints. The output is one Markdown report at
`~/.ai/<repo>/reviews/<date>-mr-<iid>-<branch>-<author>.md`.

An empty argument means "the MR of the current branch". Outside the MR's repo, only a URL works.

## REQUIRED SUB-SKILL

Use `review-branch` for the audit and the report. Give it the `target_ref` from `fetch` as the
parent override (see "Parent override" in `review-branch`). `target_ref` is the fresh
`<remote>/<target>` remote-tracking ref. Do not use the local `target_branch`, because it can be
out of date. Do not do again what `review-branch` does: git discovery, severity buckets, and the
finding format. After it writes the report, add the MR context to that file (see "Report").

## Helper scripts

The shared script `fetch-gitlab-mr.sh` does all GitLab fetches and JSON parsing. The shared script
`herdr-worktree.sh` does the worktree step. Run it with `--help` for its usage. The working
directory is not the skill directory. Always run both scripts by their absolute paths. Shell
variables do not persist between Bash calls. Start each command that uses `$FMR` or `$HWT` with the
bindings:

```sh
FMR=~/.config/ai/bin/fetch-gitlab-mr.sh; HWT=~/.config/ai/bin/herdr-worktree.sh
```

In the workflow, `$iid`, `$clone`, `$path`, and the other values from script output are the literal
values. Write them into each later command.

Do not do again inline what the scripts do. Subcommands:

- `"$FMR" preflight` - runs the prerequisite checks in fail-fast order: `glab` and `jq` are
  installed, the session runs in a Herdr pane, and `glab` is authenticated. Prints `ok`, or stops
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
- `"$HWT" <branch> --repo <clone> --move-pane` - opens the worktree of the branch as a Herdr
  workspace, or uses the workspace that exists. Moves the calling pane into it. JSON: `path`,
  `workspace_id`, `pane_id`, `root_pane_id`, `created`, `moved`.
- `"$FMR" discussions <iid> [project]` - a JSON array of normalized threads. The script removes the
  threads that have only system notes. Fields: `id`, `individual_note`, `resolvable`, `resolved`,
  `note_count`, `authors`, `first_body` (at most 280 characters), `files`.
- `"$FMR" diff-check <iid> [target]` - exits `0` if the files in the local `target...HEAD` are the
  same as the files of the MR. Else exits `1` with the file difference on stderr. Give the resolved
  `target_branch` to prevent one more `glab mr view` call.

Exit codes: `0` ok, `1` usage or parse error, `2` not found, `3` ambiguous, `4` a missing tool,
missing auth, or not in Herdr, `5` network. Exit `3` means more than one open MR for the branch,
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
4. `cd "$clone" && "$FMR" fetch "$source_branch" "$target_branch" "$project_path"` - get
   `target_ref` (for example `origin/main`) from the JSON.
5. `"$HWT" "$source_branch" --repo "$clone" --move-pane` - get `path` from the JSON. Tell the user
   that the pane is now in the worktree workspace at `path`.
6. Go into the worktree. If the session working directory is already `path`, skip this step. Else
   call `EnterWorktree` with `path`. If it rejects the path (the session started outside `clone`),
   start each later Bash command with `cd "$path" &&`, and give file tools absolute paths below
   `path`.
7. Get the report path with the `mr-<iid>` prefix (see "Report"). Use `review-branch` with
   `$target_ref` as the parent override, and tell it to write the report to that path. Do not
   rename the file after. Read the report before you add to it.
8. `"$FMR" discussions "$iid" "$project_path"` - select the threads for the report (see
   "Discussion filtering").
9. Optional: `"$FMR" diff-check "$iid" "$target_branch"`. If it exits `1`, write the difference in
   the report.
10. Add the MR context to the report (see "Report").
11. Reply as `review-branch` "Final reply" tells. Add a line with the worktree `path`. Keep the
    worktree. The user removes it as any other Herdr workspace.

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
`review-branch` helper with `mr-<iid>` as the prefix. Do not make the slug yourself:

```sh
path="$(~/.claude/skills/review-branch/report-path.sh "$target_ref" "mr-<iid>")"
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

## Hard constraints

All constraints of `review-branch`, and also:

- No `glab mr approve`, `glab mr note --message`/`-m`, `glab mr update`, `glab mr merge`,
  `glab mr close`, `glab mr revoke`, or other write subcommands.
- No API `POST`, `PUT`, or `DELETE`.
- No `git push`, commits, amends, or rebases.
- Branch changes occur only through `"$FMR" fetch` (fast-forward only) and `"$HWT"` (worktree).
  The branches of the user's checkouts do not change.

## Red flags - stop and think again

- You are about to use `review-branch` without the MR's `target_ref` as the parent override. The
  default parent detection selects the nearest local ancestor branch. For stacked MRs, the
  findings are then wrong.
- You are about to call `glab mr` with `-m`, `--message`, `approve`, `merge`, `update`, or
  `note create`. This skill is read-only.
- You copy full discussion text into the report. Write a summary.
- You skip the worktree because "the diff is sufficient". `review-branch` needs the working tree to
  examine the files, not only the diff hunks.
- You are about to run `git checkout` or `git switch` in the user's repo. Use the worktree from
  `"$HWT"`.
- There is more than one open MR for the branch, and you selected one without a question. Ask the
  user.
- You call `glab mr view`, `glab api .../discussions`, or `glab mr list` directly, not through
  `$FMR`. The script defines the JSON format. Direct calls give a different format.
