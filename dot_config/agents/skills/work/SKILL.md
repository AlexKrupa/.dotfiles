---
name: work
description: >-
  When the user runs /work, use this skill. It starts a ticket, or work with no ticket: in a new herdr
  worktree workspace with its own agent, or as the next stacked branch in the current
  worktree. Also continues an existing branch, GitLab MR, or MR pipeline in its own workspace.
  Also splits a different issue off the default branch into a new workspace with a handoff.
argument-hint: "[ticket | branch | MR] [split] [fresh | continue] [from <ref>] [<model> <effort>]"
disable-model-invocation: true
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/work-start.sh *)
  - Bash(~/.config/agents/bin/fetch-gitlab-mr.sh *)
---

# work

Starts work on one ticket. The agent that does the work gets the user's message and reads the
ticket itself.

Input: the skill arguments are the user's message, in free text. It can contain a ticket key, a
tracker URL, a branch, a GitLab MR, a base, a model, and an effort, in any order.

## Prerequisites

- The session runs in a herdr pane (`HERDR_ENV=1`).
- The current folder is in the repo: the main checkout or one of its worktrees.

## Modes

- `existing`: the message names a branch that exists (step 1). The work continues on that branch
  in its own worktree, with a new agent. This mode applies in the main checkout and in a linked
  worktree.
- `split`: the message has the option word `split` or `fork`. The work starts as in `new` mode,
  also from a linked worktree. This session stays as it is. It sends a handoff to the new agent.
  Use it for a different issue that this session found, for example a flaky test on the default
  branch.
- Else, `work-start.sh mode` in the skill folder prints the mode:
  - `new` (main checkout): the work starts in a new worktree from the default branch, with a new
    agent.
  - `next` (linked worktree): the old work is done. The work starts on a new branch in this
    worktree, stacked on the current branch or on a top branch of its stack. This session clears
    after the turn and gets the new prompt with a handoff from this session.

## Steps

1. Existing branch. In split mode, skip this step: a URL or a branch name in the message is
   context for the new work. Else, find the branch in the message:
   - A GitLab MR URL, pipeline URL, or job URL, or an MR reference `!<iid>`: run
     `~/.config/agents/bin/fetch-gitlab-mr.sh resolve <URL or iid>`. The branch is `source_branch` in
     the JSON, and the MR title is `title`. If the script fails, report its stderr and stop.
   - A branch name, for example `feature/foo`: the branch exists if
     `git show-ref --verify refs/heads/<name>` or `git ls-remote --exit-code --heads origin <name>`
     finds it.
   - Else, there is no existing branch.
   - If the branch is the current branch (`git branch --show-current`), there is no existing
     branch. The URL or name in the message is context for the new work.
2. Ticket id:
   - An issue key of the repo's tracker in the message, as a key or in a tracker URL, for example
     `ABC-123` or `https://<site>.atlassian.net/browse/ABC-123`. The project instructions tell the
     tracker and its key format. If the message has more than one key, ask the user which key is
     the ticket.
   - Else, in existing mode: if the branch name starts with an issue key, that key is the ticket
     id.
   - Else, use the placeholder id from the repo's agent instruction file (`CLAUDE.md` or
     `AGENTS.md`), for example `ABC-0`. If the repo has
     no placeholder id, ask the user for a ticket id.
3. Mode: if the message has the word `split` or `fork`, it is split mode. If step 1 found a
   branch, it is existing mode. Else, run `work-start.sh mode` in the skill folder. Next mode:
   run `work-start.sh tops`. Each output line is a top branch of the stack
   above the current branch. If there is output, ask the user: stack on the current branch, or
   on a top branch? If there is more than one top branch, ask which. Then end the turn and
   continue after the answer.
4. Slug text, in English words. The script also makes the session name from it.
   - An MR from step 1: the slug text is the MR title.
   - Real ticket id: read only the ticket title, with the tracker tool from the project
     instructions. The slug text is the title. If the context has no tool that reads the tracker,
     use the placeholder rule below.
   - Placeholder id: 3 to 6 words that tell what the message asks for. Do not read the tracker.
     Existing mode with no MR has no slug text.
   - If the tracker read fails or the ticket does not exist, stop and report it. Do not run the
     script.
5. New, split, and existing mode:
   - Base, new and split mode only: "from <remote ref>", for example
     "from `origin/release-1.2`". Use the ref as the user wrote it. If the user names a local
     branch as the base, tell the user to run `/work` in the worktree of that branch, and stop.
   - Model and effort: for example "opus high" gives `--model opus --effort high`. The user can
     give only one of the two.
   - Effort: if the user gave none, pick it from the task: the message, and the ticket title in
     new mode. Start at `medium`. If the task clearly matches a different level, use that level.
     If you are not sure, use the lower level.
     - `low`, less common: a trivial change. The task names the change and its location, for
       example a typo, a text change, or a version bump.
     - `medium`, the default for most changes: features and bug fixes where the answer is in
       the area that the task points to. Library docs, a code base search, and a small design
       choice are still `medium`.
     - `high`, less common: a harder change. The answer is outside that area, for example in
       other repos or in many modules, or the task has several separate unknowns.
     - `xhigh`, rare: a very hard change with unknowns. No test shows that an answer is
       correct, so the agent must compare possible answers. Examples:
       - a bug with no reproduction
       - a performance or concurrency problem with many possible causes
       - an architecture choice across modules that the task does not settle

       Investigation alone, or a design choice in one module, is `high` at most.
     - Never `max`, unless the user asks for it.
   - If the user gave no model, do not add `--model`.
   - In a `nono` sandbox (`printenv NONO_CAP_FILE` prints a path), `--effort` is the only agent
     flag. Do not add `--model`. If the user gave a model, tell the user to set the model in the
     new agent.
6. Next mode:
   - No base and no agent flags. If the user gave a model or an effort, tell the user to set it
     in the agent after the clear.
   - Handoff: the word `fresh` or `continue` in the message, as an option word like a model
     word. If the message has neither word, use `continue`.
     - `fresh`: the handoff has only the stack base. Add no handoff options.
     - `continue`: add `--continue`. If the MR URL of the current branch is in this session,
       add `--mr <URL>`. Else the script finds it with `glab`. Write a summary of this session
       for the new agent:
       - the status of the current branch: done, pushed, or with open items
       - decisions, with their reasons
       - facts that this session found and the next work needs
       - the related spec and plan files that are important, and why
   - If the user selected a top branch in step 3, add `--onto <branch>`.
   Split mode: add `--split`. The words `fresh` and `continue` work as in next mode. With
   `continue`, add `--continue` and no `--mr`. The summary tells only what the new work needs:
   - the issue: for example the test name, the failure text, a CI job URL
   - what this session found about the cause, and what it did not find
   - the files and the commands that are important
7. Run the script. The prompt goes on stdin in a quoted heredoc. The prompt starts with the skill
   arguments, word for word:
   - Do not summarize or fix the message. Ticket URLs and option words such as "haiku" or
     "from `origin/release-1.2`" stay in the message.

   The slug text and the branch name go in single quotes, with each `'` in the slug text replaced
   by a space. A ticket title can contain `` ` `` or `$`, and the shell runs these in double
   quotes.

   New mode:

   ```sh
   <skill folder>/work-start.sh ABC-123 'Implement foo' -- --effort low <<'PROMPT'
   <the user's message>
   PROMPT
   ```

   If the user named a base, add `--base <ref>` before `--`. In new, split, and next mode,
   if the repo's agent instruction file has a placeholder id, add `--placeholder <id>` before
   `--`. Split mode: the new mode command with `--split` before `--`. With `continue`, also add
   `--continue`, and the summary goes on fd 3 as in next mode. Next mode: the same
   command with the ticket id, the slug text, and the handoff options from step 6, and no
   `--base` and no `--` part. With `continue`, the summary goes on fd 3 in a second quoted heredoc:

   ```sh
   <skill folder>/work-start.sh ABC-123 'Implement foo' --continue \
     --placeholder ABC-0 <<'PROMPT' 3<<'SUMMARY'
   <the user's message>
   PROMPT
   <the summary>
   SUMMARY
   ```

   Next mode in a `nono` sandbox: first run `printenv NONO_CAP_FILE`. If it prints a path, run
   the script as a background task. `nono` blocks `herdr` calls from a detached helper, so there
   the script runs its helper in the foreground of the background task. Then read the output file
   of the task once. If the file is empty, read it again. JSON is exit `0`. A line that starts
   with `work-start:` is an error. If the line has `agent not ready`, it is exit `4`. Else, it is
   exit `1`.

   Existing mode: if the slug text is an MR title or a ticket title, add it. Then add `--branch <name>`. Do not
   add `--base`:

   ```sh
   <skill folder>/work-start.sh ABC-123 'Implement foo' --branch 'ABC-123/foo' \
     -- --effort low <<'PROMPT'
   <the user's message>
   PROMPT
   ```
8. Report the result, then end the turn. The user fixes each error, so the turn has no more tool
   calls after the report. The stale bump branch below is the only exception.
   - Exit `1`, existing mode, the stderr has `diverged`, and this turn loaded `/bump`: the local
     branch can be from an older bump with the same branch name. Run `git fetch origin`. Find each dependency version that
     `git diff origin/<default>...<branch>` changes. If `origin/<default>` has the same version or
     a newer version of each dependency, the local branch is stale. Run the script again with
     `--reset-local` after `--branch <name>`, then report its result. Else, report the error.
   - Exit `0`, new, split, or existing mode: one line from the JSON:
     `<branch> - <worktree> - <model or "default model"> - <effort> (<picked or given>)`.
   - Exit `0`, next mode: "`<branch>` on `<base>`, `<fresh or continue>` handoff. This session
     clears after this turn and starts the new prompt. Do not type in this pane until the prompt
     shows."
   - Exit `1`: the stderr text, word for word. The error is a report for the user, not a
     task. The repo and the worktree stay as they are: the user fixes the cause, then runs
     `/work` again.
   - Exit `1` and the stderr text ends with `(branch <branch> stays)`, new, split, or next mode:
     also tell the user that `/work` again needs a new branch name. The branch in the message
     stays. If the message names `herdr agent start` or `herdr agent prompt`, its herdr worktree
     workspace stays too. The user can continue there or remove them.
   - Exit `1` and the stderr text ends with `(branch <branch> stays)`, existing mode: also tell
     the user that the herdr worktree workspace stays. The user can continue there, or close it
     and run `/work` again.
   - Exit `4`: the stderr text names the pane id. Run
     `herdr agent read <pane-id> --source visible` and report what blocks the agent.
     The prompt was not sent. Tell the user to send the message in that pane after the block is
     gone.

If the new prompt does not show in next mode, the log is `${TMPDIR:-/tmp}/work-next.log`. The user
can clear the session, then send the message by hand.
