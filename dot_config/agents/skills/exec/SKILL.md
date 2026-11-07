---
name: exec
description: >-
  Use when the user runs /exec after a `superpowers:writing-plans` handoff. Also use when the
  Superpowers pipeline starts a saved plan, when a plan execution ends, and for
  `/exec review <plan>`.
argument-hint: "[keep] [subagent | native] [low | medium | high | xhigh | max] [review <effort>]"
disable-model-invocation: true
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/exec.sh *)
---

# exec

Runs a superpowers plan in two phases. Each phase has its own session in the same multiplexer pane:

1. Execution: implements the plan. A helper script sets the effort and submits the superpowers
   execution command with the plan path. The script first clears this agent session, unless the
   skill arguments have `keep`.
2. Review: `review-me` and `draft-pr`. After the last task, the execution session follows "Review
   handoff". The script clears the session and submits `/exec review <plan>`. A clear gives the
   review a full context, because auto-compact is off and a full context stops the session.

There are three callers:

- The user runs `/exec` in place of a reply to the `superpowers:writing-plans` handoff. This means
  that the user approved the plan.
- The Superpowers pipeline in the user instructions tells the agent to follow this skill after
  `superpowers:writing-plans` saves the plan. The user approved the spec, and that is also the
  approval of the plan. There is no handoff reply from the user.
- The prompt is `/exec review <plan>`. Read `review.md` in the skill folder and follow it with the
  plan path. Do not do the other sections of this file.

Input: the skill arguments can contain `keep`, a mode (`subagent` or `native`), an effort level,
and `review <effort>`. All are optional.

## Prerequisites

The session runs in a herdr pane or a Rex pane. The script checks it.

## Steps

1. Plan path. Find the last `superpowers:writing-plans` handoff in the conversation: "Plan
   complete and saved to `<path>`". In the pipeline, use the plan that `superpowers:writing-plans`
   saved in this session. If there is no plan path, reply "No plan handoff in this conversation."
   and stop. Else, read the plan.
2. Mode. If the skill arguments have a mode, use it. Else, ignore the recommendation in the
   handoff, and use the first rule that matches:
   1. The plan and the code that it touches fit in the context that the execution has, with
      space left: `native`. Estimate the size from the plan. Do not read the code for this.
      - Without `keep`, the execution has a full session with only the plan in it. Thus
        `native` can run a longer plan than the planning session assumed.
      - With `keep`, the execution has only the context that is left in this session.
   2. Else: `subagent`.
3. Effort. If the skill arguments have an effort, use it. Else, use these rules. The plan did the
   design, so the executor needs less reasoning:
   - `medium`: most steps are exact. They give the full code, or a mechanical edit at a named
     location, and the commands.
   - `high`: most steps leave design choices open, or one step needs design work or an
     investigation that the plan does not contain.
   - Do not pick `low`: a failing test needs reasoning. Do not pick `xhigh` or `max`: the plan
     already contains the design.
4. Review effort: the value after `review` in the skill arguments, else `medium`. The review
   session sends the audit to subagents and applies fixes from their reports, so it needs little
   reasoning.
5. Run `printenv NONO_CAP_FILE`. If it prints a path, this session runs in a `nono` sandbox.
6. Run the script. Add `--fresh` unless the skill arguments have `keep`:

   ```sh
   <skill folder>/exec.sh [--fresh] <subagent|native> <effort> <review effort> '<plan path>'
   ```

   In a `nono` sandbox, run it as a background task. `nono` blocks `herdr` calls from a detached
   helper. There, the script runs its helper in the foreground of the background task. Then read
   the output file of the task once. If the file is empty, read it again. A first line
   `<label> - <effort> - <plan>` is exit `0`. A line that starts with `exec:` is exit `1`.

   If the script exits `1` with "exec: this session does not run in a multiplexer pane", use the
   superpowers execution skill of the mode in this session, with the plan path:
   `superpowers:subagent-driven-development` for `subagent`, `superpowers:executing-plans` for
   `native`. Before that, tell it in one line: "No multiplexer pane: the plan runs in this session,
   with the effort of this session." After the last task, do "Review handoff". This fallback ends
   the steps. Do not do step 7.
7. Report the result, then end the turn. The script waits until the turn ends, so the turn has no
   more tool calls after the report.
   - Exit `0`: the stdout line, then one line per decision: `Mode: <mode> - <how>.`,
     `Effort: <effort> - <how>.`, and `Review effort: <effort> - <how>.` For each decision,
     `<how>` is "from the argument" or "<reason>". Each reason is one sentence. Then, without
     `keep`: "This session clears after this turn." With `keep`: "The plan command starts after
     this turn." Then: "Do not type in this pane until the plan command shows."
   - Exit `1`: the stderr text, word for word.

If the plan command does not show, the log is `${TMPDIR:-/tmp}/exec.log`. The user can send the
command by hand. If the skill arguments have no `keep`, the user first clears the session.

## Review handoff

The execution session does this after the last task of the plan. The input is the review effort.
If the prompt gave no review effort, use `medium`.

1. Make sure that all tasks of the plan are done and that `git status --porcelain` is empty.
   `review-me` stops on a dirty working tree, and after the clear no session knows the reason for
   the changes. If the tree is not clean, stop and show the paths.
2. Run `printenv NONO_CAP_FILE`, then run the script with the rules of step 6:

   ```sh
   <skill folder>/exec.sh review <review effort> '<plan path>'
   ```

   If the script exits `1` with "exec: this session does not run in a multiplexer pane", read
   `review.md` in the skill folder and follow it in this session.
3. Report the result, then end the turn:
   - Exit `0`: the stdout line, then "This session clears after this turn." Then: "Do not type in
     this pane until the review command shows."
   - Exit `1`: the stderr text, word for word.
