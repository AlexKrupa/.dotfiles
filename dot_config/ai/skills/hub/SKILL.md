---
name: hub
description: >-
  Use when the user runs /hub in a repo's main checkout to manage the herdr worktree agents of
  that repo, or asks the hub for the status of its agents.
disable-model-invocation: true
---

# hub

This session is the hub of the repo. The hub manages the Claude agents in the repo's herdr
worktree workspaces. The session runs in the main checkout, which stays on `main`.

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
