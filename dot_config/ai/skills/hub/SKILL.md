---
name: hub
description: >-
  Use when the user runs /hub in a repo's main checkout to manage the herdr worktree agents of
  that repo, watch its GitLab MR and pipeline events, and keep the main checkout on the newest
  commit, or asks the hub for the status of its agents.
disable-model-invocation: true
---

# hub

This session is the hub of the repo. The hub manages the Claude agents in the repo's herdr
worktree workspaces, and tells the user about GitLab events for the MRs of the user and the
default branch. The session runs in the main checkout, which stays on the default branch. The pull
task keeps the checkout on the newest commit of that branch.

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

The watch finds GitLab events for the MRs of the user and failed pipelines of the default branch,
in the project of this repo. It gives no output while there are no events.

1. After the first status report, start the watch: run
   `~/.claude/skills/hub/hub-watch-gitlab.sh --interval 120` as a background Bash task. Start it
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
   2. Run `~/.claude/skills/hub/hub-status.sh`. Output two lines for each event:

      ```text
      <kind> !<iid> <title> - @<actor>: <detail>
      <url>
      ```

      For a `default-failed` event, the first line is `<kind> <branch> - <detail>`.

      If `hub-status.sh` shows an agent on `branch`, add ` (agent <pane id>)` to the first line.
      For a `merged` event, if `git worktree list` shows `branch`, add a third line:
      `Worktree <path> can be removed.`
   3. Start the watch again.
3. When the task stops with exit `1`, report its stderr text and run
   `herdr notification show 'Hub watch stopped' --body '<stderr text>' --sound request`. Do not
   start the watch again. If the text names a token scope, tell the user to add that scope to the
   token of `glab`.
4. If the user asks to stop the watch, stop the task. If the user asks to start it, start it.

## Pull

The pull fetches the default branch and fast-forwards the main checkout to it. It skips a round
while a different herdr agent runs in the main checkout. It gives no output.

1. After the watch starts, start the pull: run `~/.claude/skills/hub/hub-pull.sh --interval 120`
   as a background Bash task. Start it only if no pull task runs.
2. When the task stops with exit `1`, report its stderr text and run
   `herdr notification show 'Hub pull stopped' --body '<stderr text>' --sound request`. Do not
   start the pull again. The user fixes the cause, for example changes in the main checkout.
3. If the user asks to stop the pull, stop the task. If the user asks to start it, start it.
