---
name: exec
description: >-
  Use when the user runs /exec after a superpowers:writing-plans handoff, or when the Superpowers
  pipeline in the user instructions starts the execution of a saved plan. Executes the plan in a
  cleared session in the same herdr pane or, with "keep", in this Claude session.
argument-hint: "[keep] [subagent|native] [low|medium|high|xhigh|max]"
disable-model-invocation: true
allowed-tools:
  - Bash(~/.claude/skills/exec/exec.sh *)
---

# exec

Executes a superpowers plan. After this turn, a helper script sets the effort and submits the
superpowers execution command with the plan path. The script first clears this Claude session,
unless `$ARGUMENTS` has `keep`. There are two callers:

- The user runs `/exec` in place of a reply to the writing-plans handoff. This means that the user
  approved the plan.
- The Superpowers pipeline in the user instructions tells the agent to follow this skill after
  writing-plans saves the plan. The user approved the spec, and that is also the approval of the
  plan. There is no handoff reply from the user.

Input: `$ARGUMENTS` can contain `keep`, a mode (`subagent` or `native`), and an effort level. All
are optional.

## Prerequisites

The session runs in a herdr pane (`HERDR_ENV=1`). The script checks it.

## Steps

1. Plan path. Find the last writing-plans handoff in the conversation: "Plan complete and saved to
   `<path>`". In the pipeline, use the plan that writing-plans saved in this session. If there is
   no plan path, reply "No plan handoff in this conversation." and stop. Else, read the plan.
2. Mode. If `$ARGUMENTS` has a mode, use it. Else, ignore the recommendation in the handoff, and
   use the first rule that matches:
   1. The plan and the code that it touches fit in the context that the execution has, with
      space left: `native`. Estimate the size from the plan. Do not read the code for this.
      - Without `keep`, the execution has a full session with only the plan in it. Thus
        `native` can run a longer plan than the planning session assumed.
      - With `keep`, the execution has only the context that is left in this session.
   2. Else: `subagent`.
3. Effort, if `$ARGUMENTS` has no effort. The plan did the design, so the executor needs less
   reasoning:
   - `medium`: each step is exact. It gives the full code, or a mechanical edit at a named
     location, and the commands.
   - `high`: some steps leave design choices open, or need investigation or debugging.
   - Do not pick `low`: a failing test needs reasoning. Do not pick `xhigh` or `max`: the plan
     already contains the design.
4. Run `printenv NONO_CAP_FILE`. If it prints a path, this session runs in a `nono` sandbox.
5. Run the script. Add `--fresh` unless `$ARGUMENTS` has `keep`:

   ```sh
   ~/.claude/skills/exec/exec.sh [--fresh] <subagent|native> <effort> '<plan path>'
   ```

   In a `nono` sandbox, run it with the Bash tool option `run_in_background: true`. `nono` blocks
   `herdr` calls from a detached helper, so there the script runs its helper in the foreground of
   the background task. Then read the output file of the task once, with the Read tool. If the
   file is empty, read it again. A first line `<skill> - <effort> - <plan>` is exit `0`. A line
   that starts with `exec:` is exit `1`.

   If the script exits `1` with "exec: this session does not run in a herdr pane", use the
   superpowers execution skill of the mode in this session, with the plan path:
   `subagent-driven-development` for `subagent`, `executing-plans` for `native`. Before that,
   tell it in one line: "No herdr pane: the plan runs in this session, with the effort of this
   session." This fallback ends this skill. Do not do step 6.
6. Report the result, then end the turn. The script waits until the turn ends, so the turn has no
   more tool calls after the report.
   - Exit `0`: the stdout line, then one line per decision: "Mode: <mode> - <how>." and
     "Effort: <effort> - <how>." For mode and for effort, `<how>` is "from the argument" or
     "<reason>". Each reason is one sentence. Then, without
     `keep`: "This session clears after this turn." With `keep`: "The plan command starts after
     this turn." Then: "Do not type in this pane until the plan command shows." Then, out
     of a `nono` sandbox: "The effort stays set for later sessions of this model: `/effort auto`
     resets it." In a `nono` sandbox: "The effort applies to this session. If
     `~/.claude/settings.json` has an effort for this model, that effort applies at the next
     start."
   - Exit `1`: the stderr text, word for word.

If the plan command does not show, the log is `${TMPDIR:-/tmp}/exec.log`. The user can send the
command by hand, after `/clear` if `$ARGUMENTS` has no `keep`.
