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

The watch gives only the events that need the model. The daemon handles the other events, and the
board pane next to the hub shows them: `pull-blocked`, `note`, `reaction`, and the items of own
worktrees. The next report also shows their rows.

A `default-failed` event is a failed pipeline of the default branch. Its `iid` and `title` are
null. Its `previous` is the status of the earlier default-branch pipeline. All other events are MR
events. The `actor` of an `opened` event is the MR author.

Each event has `row`: the number of its row in the report. An event that waits for the user
is an open item, for example a to-do item or a failed pipeline. The watch keeps the open items
and closes them when GitLab shows that their cause is gone.

For each result with exit `0`, do these steps:

1. For each `default-failed` event, do "Auto-debug". An `opened` or `todo` event comes only if
   the daemon cannot read the MR author (see "Review and bump agents"). Start no agent for it. Each
   action gives a cell: the Proposal or result text of a row.
2. Run the host command "Report" with the JSON of your actions, and output its stdout word for
   word. The JSON fields:
   - `cells`: the text for each row, for example `{"2": "Review agent started"}`.
   - `agent`: the rows of the events that an agent handles now. An open item in it closes.
   - `close`: the rows that need nothing more.
   - `add`: a row with no event, as `{"section": "agent", "iid": <iid or null>, "what": "<text>",
     "result": "<text>"}`. The section `needs` opens an item that waits for the user.
3. Start the watch again.

A result of an action that comes after the report, for example of a background task, is an `add`
row of the section `agent`. Run the report command with it, and output its stdout word for word.

## Items of own worktrees

The watch daemon polls the MRs of each own worktree, also when no agent runs in the worktree, and
the open MRs of the user that have no worktree. If no agent waits for an event of these MRs, its
open item comes to the hub. The board shows it as one row, for example `!12: @anna commented`. The
user starts work on it with `/work`.

## Review and bump agents

The daemon starts the review and bump agents, and the board shows the result. A bump agent starts
for each new MR or to-do item of a bot: an MR author whose username has `renovate` or
`dependabot`. A review agent starts for each review request of a person, unless a review report
`~/.ai/<repo>/reviews/*-mr-<iid>-*.md` exists. Each agent works in its own herdr worktree
workspace. After a bump agent starts, the board shows `The bump agent of <old branch> is stale`
for each older bump agent of the same dependency. Its workspace stays, because it can contain
changes. The `opened` event of an MR of a person goes away with no row. If the start fails, the
board shows the error text, and the row stays an open item. The user fixes the cause.

## Auto-debug

The daemon retries each failed job of a default-branch pipeline with a runner failure, 2 times at
most, and the board shows the results. The runner reasons are `runner_system_failure`,
`stuck_or_timeout_failure`, `scheduler_failure`, and `api_failure`. A `default-failed` event has
only the other jobs, in `jobs` and `failed`. A retried job that fails for another reason comes as
a new `default-failed` event with only that job. For the jobs of the event, the hub starts a debug
agent in its own herdr worktree workspace. Do these steps for each `default-failed` event. The
pipeline id is the last part of `url`. The row is the row of the event. Put it in `agent`. Each
result below is its cell, or an `agent` row with `iid` null if it comes after the report.

1. Triage. Start one Agent call in the background with this prompt. `<logs command>` is the host
   command for the logs of the failed jobs. `<jobs>` is the `jobs` list of the event.

   ```text
   Run `<logs command> <pipeline id>` in <main checkout>. Look only at the jobs <jobs>.
   Return one line for each job, with a tab between the fields:
   <job id>  <name>  <error lines>  <suspect cause>
   Join the error lines (3 at most) with " | ". Read only: retry no job and change no file.
   ```

   Do not wait for the result. When it comes, do step 2.
2. One debug workspace covers all jobs of one incident. Find the open debug workspace: a line of
   `~/.claude/skills/hub/hub-status.sh` with a branch that matches
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
2. Run this command, with the triage lines of all jobs:

   ```sh
   ~/.claude/skills/work/work-start.sh <placeholder> 'debug <branch> pipeline <id>' \
     --placeholder <placeholder> <<'PROMPT'
   Find why the default-branch pipeline <url> fails, and fix it.

   Findings of a first triage. Use them as a start, and make sure that they are correct:
   <triage lines>

   You have approval to commit the fix. Then finish the branch as the global instructions
   tell: `review-me` in auto mode, then `draft-pr`.
   PROMPT
   ```

3. Exit `0`: the result is `Debug agent started`. Other errors: the result is the stderr text,
   word for word.
