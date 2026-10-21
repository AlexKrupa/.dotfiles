# Watch: hub

The role file of `hub`: the hub mode for the project of the repo. The watch finds to-do items, new
MRs of other people, comments on MRs of other people, reactions on your comments in these MRs, and
failed pipelines of the default branch. The hub has its own report and notification, so the "MR
events" part of `common.md` does not apply.

## Start

After the first status report of `hub`, run the hub mode watch command.

On exit `1`, the notification is
`herdr notification show 'Hub watch stopped' --body '<stderr text>' --sound request`.

## Events

For an MR with a running review watch, for example of a review agent or a bump agent, the watch
gives only the review request and the `opened` event. That agent reports the other events.

A `default-failed` event is a failed pipeline of the default branch. Its `iid` and `title` are
null. Its `previous` is the status of the earlier default-branch pipeline. All other events are MR
events. The `actor` of an `opened` event is the MR author.

For each result with exit `0`, do these steps:

1. Do "Router" for each MR with an `opened` event or a `todo` event with the `detail`
   `review_requested`. Remove the `opened` events that the router does not keep. If no events
   remain, start the watch again and give no output.
2. Send one notification. Replace each `'` in the text with a space.
   - One MR event:
     `herdr notification show '!<iid>: <kind> from @<actor>' --body '<detail>' --sound request`.
     If `actor` is empty, leave out `from @<actor>`.
   - One `default-failed` event:
     `herdr notification show '<branch> pipeline failed' --body '<detail>' --sound request`.
   - More events: `herdr notification show '<n> hub events' --body '<id>, <id>' --sound request`.
     The id of an MR event is `!<iid>`. The id of a `default-failed` event is `<branch>`.
3. Run `~/.claude/skills/hub/hub-status.sh` and `date +%H:%M`. Output the events in one
   block. Put the events of one MR in one group. Put the `default-failed` event of a branch
   in one group.

   ```text
   <HH:MM> - <n> events
   !<iid> <title> (agent <pane id>)
     - <event sentence>
     - <event sentence>
     <url>
   <branch>
     - Pipeline <id> failed
     <url>
   ```

   - Header of a group: `!<iid> <title>`. For a `default-failed` event: `<branch>`.
   - If `hub-status.sh` shows an agent on `branch`, add ` (agent <pane id>)` to the header.
   - URL of a group: if the group has one event, use its `url`. Else use the `url` without
     `#note_<id>`.
   - Event sentences. Write the first letter of each sentence as a capital letter.

     | Event                        | Sentence                                           |
     | ---------------------------- | -------------------------------------------------- |
     | `todo`, `review_requested`   | `@<actor> requested your review`                   |
     | `todo`, `mentioned`          | `@<actor> mentioned you`                           |
     | `todo`, `directly_addressed` | `@<actor> mentioned you`                           |
     | `todo`, `approval_required`  | `@<actor> requested your approval`                 |
     | `todo`, other `detail`       | `@<actor>: <detail>`, with `_` as a space          |
     | `note`                       | `@<actor> commented: "<detail>"`                   |
     | `reaction`                   | `@<actor> reacted <detail>`                        |
     | `opened`                     | `@<actor> opened a dependency bump`                |
     | all other kinds              | `<detail>`                                         |

   - Sort the groups by their most urgent event. Urgency, from high to low:
     1. `default-failed`
     2. `note`, `todo`
     3. All other events
4. For each MR, do the action that the router selected in step 1. For each `default-failed`
   event, do "Auto-debug".
5. Start the watch again.

## Router

The router selects one action for each new MR or review request. Do these steps one time for each
MR, also when the MR has an `opened` event and a `todo` event in the same round.

1. Run the host command for the MR details. The JSON has `author`,
   `labels`, `source_branch`, and `description`. If the script fails, keep the events, select no
   action, and output the stderr text below the event block.
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

## Auto-review

The hub starts a review agent for each review request from a different person. The agent works in
its own herdr worktree workspace. Do these steps for each MR for which the router selected
"Auto-review". Write each output line below the event block.

1. Look for an earlier review report:
   `ls ~/.ai/$(~/.config/agents/bin/repo-slug.sh)/reviews/*-mr-<iid>-*.md`. If a report exists,
   start no agent and output `!<iid>: Already reviewed: <report path>`. This rule applies also
   when the MR has new commits, or when the person adds the user as reviewer again.
2. The branch is `source_branch` in the JSON of "Router" step 1.
3. Ticket id: the issue key at the start of the branch name. Else, the placeholder id of the
   repo's `CLAUDE.md`. Else, start no agent and output
   `!<iid>: No placeholder id in CLAUDE.md, no review agent`.
4. Run this command. The branch name goes in single quotes. Do not add `--effort`.

   ```sh
   ~/.claude/skills/work/work-start.sh <ticket-id> --branch '<source_branch>' <<'PROMPT'
   /review-pr <mr-url>
   PROMPT
   ```

5. Result:
   - Exit `0`: output `!<iid>: Review agent <pane id> started`. The pane id is `pane_id` in the
     JSON.
   - The stderr text has "is open in herdr workspace": an agent works on the branch already. Start
     no agent. The group header has `(agent <pane id>)` from "Events" step 3.
   - Other errors: output the stderr text, word for word. The user fixes the cause.

## Auto-bump

The hub starts a bump agent for each new dependency bump MR, also when the user is not a reviewer
of the MR. The agent works in its own herdr worktree workspace. Do these steps for each MR for
which the router selected "Auto-bump". Write each output line below the event block.

1. The branch is `source_branch` in the JSON of "Router" step 1.
2. Ticket id: the issue key at the start of the branch name. Else, the placeholder id of the
   repo's `CLAUDE.md`. Else, start no agent and output
   `!<iid>: No placeholder id in CLAUDE.md, no bump agent`.
3. Run this command. The branch name goes in single quotes. Do not add `--effort`.

   ```sh
   ~/.claude/skills/work/work-start.sh <ticket-id> --branch '<source_branch>' <<'PROMPT'
   /bump <mr-url>
   PROMPT
   ```

4. Result:
   - Exit `0`: output `!<iid>: Bump agent <pane id> started`. The pane id is `pane_id` in the
     JSON.
   - The stderr text has "is open in herdr workspace": an agent works on the branch already. Start
     no agent. The group header has `(agent <pane id>)` from "Events" step 3.
   - Other errors: output the stderr text, word for word. The user fixes the cause.
5. After exit `0`, find an older bump agent of the same dependency: a `hub-status.sh` line with a
   different branch that names the same dependency, for example `renovate/foo-1.x` for a bump of
   `foo`. For each such agent, output `!<iid>: Bump agent <old pane id> is stale`. Do not close its
   workspace, because it can contain changes.

## Auto-debug

The hub sorts the failed jobs of each failed default-branch pipeline. It retries each job with a
runner failure. For all other causes, it starts a debug agent in its own herdr worktree workspace.
Do these steps for each `default-failed` event. The pipeline id is the last part of `url`. Write
each output line below the event block.

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
   the main checkout, as a background Bash task. Output
   `<branch>: job <name> retried (runner failure), 1/2`. When a task stops:
   - Exit `0` and `status` `success`: output `<branch>: job <name> passed after retry`.
   - Exit `0`, `failed`, a runner reason, and 1 retry: retry `<new_job_id>` in the same way.
     Output `<branch>: job <name> retried (runner failure), 2/2`.
   - Exit `0`, `failed`, a runner reason, and 2 retries: output
     `<branch>: job <name> failed 3 times (runner failure), stopped`. Start no debug workspace.
   - Exit `0`, `failed`, and a different reason: the job is an `other` job. Its triage line has
     `new_job_id`, `name`, `other`, no error lines, and `failure_reason`. Do step 3 for it.
   - Exit `0` and `canceled` or `skipped`: output `<branch>: job <name> <status> after retry`.
   - Exit `1` or `4`: output the stderr text.
3. Other jobs. One debug workspace covers all `other` jobs of one incident. Find the open debug
   workspace: a `hub-status.sh` line with a branch that matches
   `*/debug-<branch>-pipeline-*`.
   - No debug workspace is open: start one (see "Debug workspace").
   - A debug workspace is open, and its branch ends with `-pipeline-<pipeline id>`, or `previous`
     of the event is not `success`: this is the same incident. Start no workspace. Output
     `<branch>: Debug agent <pane id> has this incident`. The user tells that agent about the new
     jobs.
   - A debug workspace is open, and `previous` is `success`: this is a new incident. Start a new
     workspace. Output `<branch>: Debug agent <old pane id> is stale`. Do not close the old
     workspace, because it can contain changes.

### Debug workspace

1. Find the placeholder id in the repo's `CLAUDE.md`. If there is none, start no agent and output
   `<branch>: No placeholder id in CLAUDE.md, no debug agent`.
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

3. Exit `0`: output `<branch>: Debug agent <pane id> started`. Other errors: output the stderr
   text, word for word.
