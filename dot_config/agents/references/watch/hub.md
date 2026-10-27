# Watch: hub

The role file of `hub`: the hub mode for the project of the repo. The watch finds to-do items, new
MRs of other people, comments on MRs of other people, reactions on your comments in these MRs, and
failed pipelines of the default branch. The hub has its own report, so the "MR events" part of
`common.md` does not apply.

## Start

After the first status report of `hub`, run the hub mode watch command.

## Events

An MR can have a live review subscription, for example of a review agent or a bump agent. For that
MR, the watch gives only the review request and the `opened` event. That agent reports the other
events.

A `pull-blocked` event tells that the daemon cannot fast-forward the main checkout to the default
branch. Its `detail` is the reason, for example changes in tracked files. Report it. The user
fixes the cause.

A `default-failed` event is a failed pipeline of the default branch. Its `iid` and `title` are
null. Its `previous` is the status of the earlier default-branch pipeline. All other events are MR
events. The `actor` of an `opened` event is the MR author.

Each event has `row`: the number of its row in the report. An event that waits for the user
is an open item, for example a to-do item or a failed pipeline. The watch keeps the open items
and closes them when GitLab shows that their cause is gone.

For each result with exit `0`, do these steps:

1. Do "Router" for each MR with an `opened` event or a `todo` event with the `detail`
   `review_requested`. Put the row of each `opened` event that the router does not keep in
   `close`. If no other events remain, start the watch again and give no output.
2. For each MR, do the action that the router selected in step 1. For each `default-failed`
   event, do "Auto-debug". Each action gives a cell: the Proposal or result text of a row.
3. Run the host command "Report" with the JSON of your actions, and output its stdout word for
   word. The JSON fields:
   - `cells`: the text for each row, for example `{"2": "Review agent started"}`.
   - `agent`: the rows of the events that an agent handles now. An open item in it closes.
   - `close`: the rows that need nothing more.
   - `add`: a row with no event, as `{"section": "agent", "iid": <iid or null>, "what": "<text>",
     "result": "<text>"}`. The section `needs` opens an item that waits for the user.
4. Start the watch again.

A result of an action that comes after the report, for example of a background task, is an `add`
row of the section `agent`. Run the report command with it, and output its stdout word for word.

## Items of own worktrees

The watch daemon polls the MRs of each own worktree, also when no agent runs in the worktree, and
the open MRs of the user that have no worktree. If no agent waits for an event of these MRs, its
open item comes to the hub. Such an item is one row of the report, for example
`!12: @anna commented`. Start no agent for it. The user starts work on it with `/work`.

## Router

The router selects one action for each new MR or review request. Do these steps one time for each
MR, also when the MR has an `opened` event and a `todo` event in the same round.

1. Run the host command for the MR details. The JSON has `title`, `author`,
   `labels`, `source_branch`, and `description`. If the script fails, keep the events, select no
   action, and put the stderr text in the cell of the MR row.
2. Decide if the MR is a dependency bump: an MR that only changes the versions of dependencies.
   Use the title, the author, the branch, the labels, and the description. There is no fixed rule.
   - Signs of a bump: the author or the branch has `renovate` or `dependabot`. The title is
     similar to "Update dependency X to v2" or "Bump X from 1.0 to 1.1". A label is similar to
     `dependencies`. The description has a table of packages with versions.
   - Not a bump: a change to the bot configuration, for example `renovate.json` or a Renovate
     preset. An MR that a person opened for other work and that also changes a version.
   - If it is not clear, the MR is not a bump.
3. Select the action:
   - A bump: keep the events and select "Auto-bump". This rule applies also when the MR has a
     review request.
   - Not a bump, with a `review_requested` event: remove the `opened` event and select
     "Auto-review".
   - Not a bump, with no `review_requested` event: remove the `opened` event and select no
     action.
4. If the MR has an `opened` event, run the host command "Router result" with the selected
   action: `bump` for "Auto-bump", `review` for "Auto-review", `none` for no action. The `watch`
   herdr plugin uses it for the notification of the new MR.

## Auto-review

The hub starts a review agent for each review request from a different person. The agent works in
its own herdr worktree workspace. Do these steps for each MR for which the router selected
"Auto-review". The row is the row of the `review_requested` event. If no agent starts, the row
stays an open item.

1. Look for an earlier review report:
   `ls ~/.ai/$(~/.config/agents/bin/repo-slug.sh)/reviews/*-mr-<iid>-*.md`. If a report exists,
   start no agent. The cell is `Already reviewed: <report path>`. This rule applies also when the
   MR has new commits, or when the person adds the user as reviewer again.
2. The branch is `source_branch` in the JSON of "Router" step 1.
3. Ticket id: the issue key at the start of the branch name. Else, the placeholder id of the
   repo's `CLAUDE.md`. Else, start no agent. The cell is
   `No placeholder id in CLAUDE.md, no review agent`.
4. Run this command. The MR title is `title` in the JSON of "Router" step 1. The MR title and the
   branch name go in single quotes. Replace each `'` in the MR title with a space. Do not add
   `--effort`.

   ```sh
   ~/.claude/skills/work/work-start.sh <ticket-id> '<MR title>' --branch '<source_branch>' <<'PROMPT'
   /review-pr <mr-url>
   PROMPT
   ```

5. Result:
   - Exit `0`: put the row in `agent`. The cell is `Review agent started`.
   - The stderr text has "is open in herdr workspace": an agent works on the branch already. Start
     no agent. Put the row in `agent`. The cell is `An agent works on the branch`.
   - Other errors: the cell is the stderr text, word for word. The user fixes the cause.

## Auto-bump

The hub starts a bump agent for each new dependency bump MR, also when the user is not a reviewer
of the MR. The agent works in its own herdr worktree workspace. Do these steps for each MR for
which the router selected "Auto-bump". The row is the row of the `opened` event.

1. The branch is `source_branch` in the JSON of "Router" step 1.
2. Ticket id: the issue key at the start of the branch name. Else, the placeholder id of the
   repo's `CLAUDE.md`. Else, start no agent. The cell is
   `No placeholder id in CLAUDE.md, no bump agent`.
3. Run this command. The MR title is `title` in the JSON of "Router" step 1. The MR title and the
   branch name go in single quotes. Replace each `'` in the MR title with a space. Do not add
   `--effort`.

   ```sh
   ~/.claude/skills/work/work-start.sh <ticket-id> '<MR title>' --branch '<source_branch>' <<'PROMPT'
   /bump <mr-url>
   PROMPT
   ```

4. Result:
   - Exit `0`: put the row in `agent`. The cell is `Bump agent started`.
   - The stderr text has "is open in herdr workspace": an agent works on the branch already. Start
     no agent. Put the row in `agent`. The cell is `An agent works on the branch`.
   - Other errors: the cell is the stderr text, word for word. The user fixes the cause.
5. After exit `0`, find an older bump agent of the same dependency: run
   `~/.claude/skills/hub/hub-status.sh` and find a line with a different branch that names the
   same dependency, for example `renovate/foo-1.x` for a bump of `foo`. For each such agent, add
   an `agent` row with `iid` null and the text `The bump agent of <old branch> is stale`. Do not
   close its workspace, because it can contain changes.

## Auto-debug

The hub sorts the failed jobs of each failed default-branch pipeline. It retries each job with a
runner failure. For all other causes, it starts a debug agent in its own herdr worktree workspace.
Do these steps for each `default-failed` event. The pipeline id is the last part of `url`. The
row is the row of the event. Put it in `agent`. Each result below is its cell, or an `agent` row
with `iid` null if it comes after the report.

1. Triage. Start one Agent call in the background with this prompt. `<logs command>` is the host
   command for the logs of the failed jobs.

   ```text
   Run `<logs command> <pipeline id>` in <main checkout>.
   Sort each failed job:
   - runner: the `failure_reason` is `runner_system_failure`, `stuck_or_timeout_failure`,
     `scheduler_failure`, or `api_failure`. Or the log shows none of the steps of the job script.
   - other: all other jobs, and each job where it is not clear that a retry helps.
   Return one line for each job, with a tab between the fields:
   <job id>  <name>  <runner|other>  <error lines>  <suspect cause>
   Join the error lines (3 at most) with " | ". Read only: retry no job and change no file.
   ```

   Do not wait for the result. When it comes, do step 2 for the `runner` jobs and step 3 for the
   `other` jobs, at the same time.
2. Runner jobs. A job gets 2 retries at most. The runner reasons are the four reasons of step 1.
   For each `runner` job, run the host command that retries a job and waits for the new job, in
   the main checkout, as a background Bash task. The result is
   `<branch>: job <name> retried (runner failure), 1 of 2`. When a task stops:
   - Exit `0` and `status` `success`: `<branch>: job <name> passed after retry`.
   - Exit `0`, `failed`, a runner reason, and 1 retry: retry `<new_job_id>` in the same way.
     The result is `<branch>: job <name> retried (runner failure), 2 of 2`.
   - Exit `0`, `failed`, a runner reason, and 2 retries:
     `<branch>: job <name> failed 3 times (runner failure), stopped`. Start no debug workspace.
   - Exit `0`, `failed`, and a different reason: the job is an `other` job. Its triage line has
     `new_job_id`, `name`, `other`, no error lines, and `failure_reason`. Do step 3 for it.
   - Exit `0` and `canceled` or `skipped`: `<branch>: job <name> <status> after retry`.
   - Exit `1` or `6`: the stderr text.
3. Other jobs. One debug workspace covers all `other` jobs of one incident. Find the open debug
   workspace: a line of `~/.claude/skills/hub/hub-status.sh` with a branch that matches
   `*/debug-<branch>-pipeline-*`.
   - No debug workspace is open: start one (see "Debug workspace").
   - A debug workspace is open, and its branch ends with `-pipeline-<pipeline id>`, or `previous`
     of the event is not `success`: this is the same incident. Start no workspace. The result is
     `A debug agent has this incident`. The user tells that agent about the new jobs.
   - A debug workspace is open, and `previous` is `success`: this is a new incident. Start a new
     workspace. The result is also `The debug agent of <old branch> is stale`. Do not close the
     old workspace, because it can contain changes.

### Debug workspace

1. Find the placeholder id in the repo's `CLAUDE.md`. If there is none, start no agent. The
   result is `No placeholder id in CLAUDE.md, no debug agent`.
2. Run this command, with the triage lines of all `other` jobs:

   ```sh
   ~/.claude/skills/work/work-start.sh <placeholder> 'debug <branch> pipeline <id>' \
     --placeholder <placeholder> <<'PROMPT'
   Find why the default-branch pipeline <url> fails, and fix it.

   Findings of a first triage. Use them as a start, and make sure that they are correct:
   <triage lines of the "other" jobs>

   You have approval to commit the fix. Then finish the branch as the global instructions
   tell: `review-me` in auto mode, then `draft-pr`.
   PROMPT
   ```

3. Exit `0`: the result is `Debug agent started`. Other errors: the result is the stderr text,
   word for word.
