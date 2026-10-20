---
name: hub
description: >-
  Use when the user runs /hub in a repo's main checkout to manage the herdr worktree agents of
  that repo, watch its GitLab review requests, mentions, and default branch pipelines, start
  review agents and debug agents, and keep the main checkout on the newest commit, or asks the hub
  for the status of its agents.
disable-model-invocation: true
---

# hub

This session is the hub of the repo. The hub manages the Claude agents in the repo's herdr
worktree workspaces, and tells the user about GitLab events for MRs of other people and the
default branch. The draft-pr watch reports the user's own MRs. The session runs in the main
checkout, which stays on the default branch. The pull task keeps the checkout on the newest commit
of that branch.

The watch task and the pull task are background Bash tasks (`run_in_background: true`). Each task
does one round each 120 seconds: give each script `--interval 120`.

## Role

- Do no code work in this session, unless the user asks for it.
- If a hub task needs edits, for example a test, tell the user to start it with `/work` and the
  placeholder id. The work then happens in a short-lived worktree.
- Do not send prompts or keys to the worktree agents. The user talks to each agent in its pane.

## Status

Give the status when `/hub` starts, and each time the user asks for it.

1. Run `~/.claude/skills/hub/hub-status.sh`. Each output line is TSV: pane id, status, branch,
   cwd, title. If the script exits `1`, report its stderr text.
2. For each agent, find what it does:
   - If the title tells it, use the title.
   - Else, run `herdr agent read <pane-id> --source recent --lines 60`. Find the last message of
     the agent on the screen. Use one short sentence from it.
3. Output one line for each agent:

   ```text
   <status> <branch> - <what the agent does or last said>
   ```

   If the script gave no lines, output "No worktree agents."

## Watch

The watch finds to-do items, comments on MRs of other people, reactions on your comments in
these MRs, and failed pipelines of the default branch, in the project of this repo. It gives no output while there are no events.

1. After the first status report, start the watch: run
   `~/.config/agents/bin/watch-gitlab.sh --interval 120` as a background Bash task. Start it
   only if no watch task runs.
2. When the task stops with exit `0`, each output line is one JSON event with the fields `kind`,
   `iid`, `title`, `url`, `actor`, `detail`, and `branch`. A `default-failed` event is a failed
   pipeline of the default branch. Its `iid` and `title` are null. All other events are MR
   events.
   1. Send one notification. Replace each `'` in the text with a space.
      - One MR event:
        `herdr notification show '!<iid>: <kind> from @<actor>' --body '<detail>' --sound request`.
        If `actor` is empty, leave out `from @<actor>`.
      - One `default-failed` event:
        `herdr notification show '<branch> pipeline failed' --body '<detail>' --sound request`.
      - More events: `herdr notification show '<n> hub events' --body '<id>, <id>' --sound request`.
        The id of an MR event is `!<iid>`. The id of a `default-failed` event is `<branch>`.
   2. Run `~/.claude/skills/hub/hub-status.sh` and `date +%H:%M`. Output the events in one
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
        | all other kinds              | `<detail>`                                         |

      - Sort the groups by their most urgent event. Urgency, from high to low:
        1. `default-failed`
        2. `note`, `todo`
        3. All other events
   3. For each `todo` event with the `detail` `review_requested`, do "Auto-review". For each
      `default-failed` event, do "Auto-debug".
   4. Start the watch again.
3. When the task stops with exit `1`, report its stderr text and run
   `herdr notification show 'Hub watch stopped' --body '<stderr text>' --sound request`. Do not
   start the watch again. If the text names a token permission, tell the user to add that
   permission to the fine-grained token of `glab`.
4. When the task stops with exit `3`, a new hub session started its own watch. Do not start the
   watch again. Do not send a notification.
5. If the user asks to stop the watch, stop the task. If the user asks to start it, start it.

## Auto-review

The hub starts a review agent for each review request from a different person. The agent works in
its own herdr worktree workspace. Do these steps for each `review_requested` event. Write each
output line below the event block.

1. Look for an earlier review report:
   `ls ~/.ai/$(~/.config/agents/bin/repo-slug.sh)/reviews/*-mr-<iid>-*.md`. If a report exists,
   start no agent and output `!<iid>: Already reviewed: <report path>`. This rule applies also
   when the MR has new commits, or when the person adds the user as reviewer again.
2. Run `~/.config/agents/bin/fetch-gitlab-mr.sh resolve <url>`. The branch is `source_branch` in
   the JSON. If the script fails, output its stderr text and stop.
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
     no agent. The group header has `(agent <pane id>)` from "Watch" step 2.2.
   - Other errors: output the stderr text, word for word. The user fixes the cause.

## Auto-debug

The hub sorts the failed jobs of each failed default-branch pipeline. It retries each job with a
runner failure. For all other causes, it starts a debug agent in its own herdr worktree workspace.
Do these steps for each `default-failed` event. The pipeline id is the last part of `url`. Write
each output line below the event block.

1. Triage. Start one Agent call in the background with this prompt:

   ```text
   Run `~/.config/agents/bin/gitlab-pipeline.sh failed-logs <pipeline id>` in <main checkout>.
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
   For each `runner` job, run `~/.claude/skills/hub/hub-retry.sh <job id>` in the main checkout
   as a background Bash task. Output `<branch>: job <name> retried (runner failure), 1/2`. When a
   task stops:
   - Exit `0` and `status` `success`: output `<branch>: job <name> passed after retry`.
   - Exit `0`, `failed`, a runner reason, and 1 retry: run `hub-retry.sh <new_job_id>` in the
     same way. Output `<branch>: job <name> retried (runner failure), 2/2`.
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

## Pull

The pull fetches the default branch and fast-forwards the main checkout to it. It skips a round
while a different herdr agent runs in the main checkout. It gives no output.

1. After the watch starts, start the pull: run `~/.claude/skills/hub/hub-pull.sh --interval 120`
   as a background Bash task. Start it only if no pull task runs.
2. When the task stops with exit `1`, report its stderr text and run
   `herdr notification show 'Hub pull stopped' --body '<stderr text>' --sound request`. Do not
   start the pull again. The user fixes the cause, for example changes in the main checkout.
3. When the task stops with exit `3`, a new hub session started its own pull. Do not start the
   pull again. Do not send a notification.
4. If the user asks to stop the pull, stop the task. If the user asks to start it, start it.
