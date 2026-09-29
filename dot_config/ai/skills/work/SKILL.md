---
name: work
description: >-
  Use when the user runs /work to start a ticket, or work with no ticket: in a new herdr
  worktree workspace with its own Claude Code agent, or as the next stacked branch in the current
  worktree. Also continues an existing branch, GitLab MR, or MR pipeline in its own workspace.
argument-hint: "<message>"
disable-model-invocation: true
---

# work

Starts work on one ticket. The agent that does the work gets the user's message and reads the
ticket itself.

Input: `$ARGUMENTS` is the user's message, in free text. It can contain a ticket key, a tracker
URL, a branch, a GitLab MR, a base, a model, and an effort, in any order.

## Prerequisites

- The session runs in a herdr pane (`HERDR_ENV=1`).
- The current folder is in the repo: the main checkout or one of its worktrees.
- git-spice is set up in the repo (`gs repo init`).
- One-time setup: Claude trusts `~/.herdr/worktrees`. Run `claude` in that folder and accept the
  prompt.

## Modes

- `existing`: the message names a branch that exists (step 1). The work continues on that branch
  in its own worktree, with a new agent. This mode applies in the main checkout and in a linked
  worktree.
- Else, `~/.claude/skills/work/work-start.sh mode` prints the mode:
  - `new` (main checkout): the work starts in a new worktree from the default branch, with a new
    agent.
  - `next` (linked worktree): the old work is done. The work starts on a new branch on top of the
    current branch, in this worktree. This session clears after the turn and gets the new prompt.

## Steps

1. Existing branch. Find it in the message:
   - A GitLab MR URL, pipeline URL, or job URL, or an MR reference `!<iid>`: run
     `~/.config/ai/bin/fetch-gitlab-mr.sh resolve <URL or iid>`. The branch is `source_branch` in
     the JSON. If the script fails, report its stderr and stop.
   - A branch name, for example `feature/foo`: the branch exists if
     `git show-ref --verify refs/heads/<name>` or `git ls-remote --exit-code --heads origin <name>`
     finds it.
   - Else, there is no existing branch.
2. Ticket id:
   - An issue key of the repo's tracker in the message, as a key or in a tracker URL, for example
     `ABC-123` or `https://<site>.atlassian.net/browse/ABC-123`. The project instructions tell the
     tracker and its key format. If the message has more than one key, ask the user which key is
     the ticket.
   - Else, in existing mode: if the branch name starts with an issue key, that key is the ticket
     id.
   - Else, use the placeholder id from the repo's CLAUDE.md, for example `ABC-0`. If the repo has
     no placeholder id, ask the user for a ticket id.
3. Mode: existing mode if step 1 found a branch. Else, run
   `~/.claude/skills/work/work-start.sh mode`.
4. Slug text, in English words. Existing mode has no slug text and no tracker read.
   - Real ticket id: read only the ticket title, with the tracker tool from the project
     instructions. The slug text is the title. If the context has no tool that reads the tracker,
     use the placeholder rule below.
   - Placeholder id: 3 to 6 words that tell what the message asks for. Do not read the tracker.
   - If the tracker read fails or the ticket does not exist, stop and report it. Do not run the
     script.
5. New and existing mode:
   - Base, new mode only: "from <remote ref>", for example "from `origin/release-1.2`". Use the ref
     as the user wrote it. If the user names a local branch as the base, tell the user to run
     `/work` in the worktree of that branch, and stop.
   - Model and effort: for example "opus high" gives `--model opus --effort high`. The user can
     give only one of the two.
   - Effort, if the user gave none. Use the ticket title (new mode) and the message:
     - `low`: clear work with a known path and a small change.
     - `medium` or `high`: more uncertainty, more files, or more risk.
     - `xhigh`: unclear investigation or design.
     - Never `max`, unless the user asks for it.
   - If the user gave no model, do not add `--model`.
6. Next mode only: no base and no Claude flags. If the user gave a model or an effort, tell the
   user to set it with `/model` after the clear.
7. Run the script. The prompt goes on stdin in a quoted heredoc: the user's message with no
   changes. Do not summarize, fix, or add to the message. Ticket URLs and option words such as
   "haiku" or "from `origin/release-1.2`" stay in the message. The slug text and the branch name
   go in single quotes, with each `'` in the slug text replaced by a space. A ticket title can
   contain `` ` `` or `$`, and the shell runs these in double quotes.

   New mode:

   ```sh
   ~/.claude/skills/work/work-start.sh ABC-123 'Implement foo' -- --effort low <<'PROMPT'
   <the user's message>
   PROMPT
   ```

   Add `--base <ref>` before `--` only if the user named a base. Next mode: the same command with
   the ticket id and the slug text, and no `--base` and no `--` part:

   ```sh
   ~/.claude/skills/work/work-start.sh ABC-123 'Implement foo' <<'PROMPT'
   <the user's message>
   PROMPT
   ```

   Existing mode: `--branch <name>` in place of the slug text, and no `--base`:

   ```sh
   ~/.claude/skills/work/work-start.sh ABC-123 --branch 'ABC-123/foo' -- --effort low <<'PROMPT'
   <the user's message>
   PROMPT
   ```
8. Report the result, then end the turn. The user fixes each error, so the turn has no more tool
   calls after the report.
   - Exit `0`, new or existing mode: one line from the JSON:
     `<branch> - <worktree> - <model or "default model"> - <effort> (<picked or given>)`.
   - Exit `0`, next mode: "`<branch>` on `<base>`. This session clears after this turn and starts
     the new prompt. Do not type in this pane until the prompt shows."
   - Exit `1` or `2`: the stderr text, word for word. The error is a report for the user, not a
     task. The repo and the worktree stay as they are: the user fixes the cause, then runs
     `/work` again.
   - Exit `2` only, new or next mode: also tell the user that `/work` again needs a new branch
     name. The branch in the message stays. If the message names `herdr agent start` or
     `herdr agent prompt`, its herdr worktree workspace stays too. The user can continue there or
     remove them.
   - Exit `2` only, existing mode: also tell the user that the herdr worktree workspace stays.
     The user can continue there, or close it and run `/work` again.
   - Exit `3`: the stderr text names the pane id. Run
     `herdr agent read <pane-id> --source visible` and report what blocks the agent.
     The prompt was not sent. Tell the user to send the message in that pane after the block is
     gone.

If the new prompt does not show in next mode, the log is `${TMPDIR:-/tmp}/work-next.log`. The user
can type `/clear`, then send the message by hand.
