---
name: hub
description: >-
  Use when the user runs /hub in a repo's main checkout to manage the herdr worktree agents of
  that repo, watch its GitLab review requests, mentions, dependency bump MRs, and default branch
  pipelines, start review agents, bump agents, and debug agents, and keep the main checkout on the
  newest commit, or asks the hub for the status of its agents.
disable-model-invocation: true
---

# hub

This session is the hub of the repo. The hub manages the Claude agents in the repo's herdr
worktree workspaces, and tells the user about GitLab events for MRs of other people and the
default branch. The draft-pr watch reports the user's own MRs. The session runs in the main
checkout, which stays on the default branch. The pull task keeps the checkout on the newest commit
of that branch.

The pull task is a background Bash task (`run_in_background: true`). It does one round each 120
seconds: give the script `--interval 120`.

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

After the first status report, start the watch. Read
`~/.config/agents/references/watch/common.md` and follow it, with the role file `hub.md`. The
watch finds new MRs, review requests, comments, and failed default-branch pipelines, and starts
the review, bump, and debug agents.

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
