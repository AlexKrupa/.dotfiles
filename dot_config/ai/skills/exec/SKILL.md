---
name: exec
description: >-
  Use when the user runs /exec after a superpowers:writing-plans handoff, to execute the plan in
  this Claude session or, with "fresh", in a cleared session in the same herdr pane.
argument-hint: "[fresh] [subagent|native] [low|medium|high|xhigh|max]"
disable-model-invocation: true
---

# exec

Executes a superpowers plan. After this turn, a detached script sets the effort and submits the
superpowers execution command with the plan path. With `fresh`, the script first clears this
Claude session. The user runs this skill in place of a reply to the writing-plans handoff. This
means that the user approved the plan.

Input: `$ARGUMENTS` can contain `fresh`, a mode (`subagent` or `native`), and an effort level. All
are optional.

## Prerequisites

The session runs in a herdr pane (`HERDR_ENV=1`). The script checks it.

## Steps

1. Plan path. Find the last writing-plans handoff in the conversation: "Plan complete and saved to
   `<path>`". If there is no handoff, reply "No plan handoff in this conversation." and stop.
   Else, read the plan.
2. Mode, if `$ARGUMENTS` has no mode. Start from the recommendation in the handoff ("For this plan
   I recommend ..."). Check it against these reasons for `subagent`:
   - An error in one task costs much: security, money, data migration, public API, or
     concurrency.
   - Many later tasks use the interfaces from earlier tasks. A review after each task stops an
     interface error before other tasks use it.

   The reason in the handoff can show that one of them applies. Use the first rule that matches:
   1. A reason applies: `subagent`.
   2. The plan and the code that it touches fit in the context that the execution has, with
      space left: `native`. Estimate the size from the plan. Do not read the code for this.
      - With `fresh`, the execution has a full session with only the plan in it. Thus `native`
        can run a longer plan than the planning session assumed.
      - Without `fresh`, the execution has only the context that is left in this session.
   3. Else: `subagent`.
3. Effort, if `$ARGUMENTS` has no effort. The plan did the design, so the executor needs less
   reasoning:
   - `medium`: each step is exact. It gives the full code, or a mechanical edit at a named
     location, and the commands.
   - `high`: some steps leave design choices open, or need investigation or debugging.
   - Do not pick `low`: a failing test needs reasoning. Do not pick `xhigh` or `max`: the plan
     already contains the design.
4. Run the script. Add `--fresh` only if `$ARGUMENTS` has `fresh`:

   ```sh
   ~/.claude/skills/exec/exec.sh [--fresh] <subagent|native> <effort> '<plan path>'
   ```

5. Report the result, then end the turn. The script waits until the turn ends, so the turn has no
   more tool calls after the report.
   - Exit `0`: the stdout line, then one line per decision: "Mode: <mode> - <how>." and
     "Effort: <effort> - <how>." For mode, `<how>` is "from the argument", "kept, <reason>",
     "changed from <recommended mode>, <reason>", or "no recommendation, <reason>". For effort,
     `<how>` is "from the argument" or "<reason>". Each reason is one sentence. Then, with
     `fresh`: "This session clears after this turn." Without `fresh`: "The plan command starts
     after this turn." Then: "Do not type in this pane until the plan command shows. The effort
     stays set for later sessions of this model: `/effort auto` resets it."
   - Exit `1`: the stderr text, word for word.

If the plan command does not show, the log is `${TMPDIR:-/tmp}/exec.log`. The user can send the
command by hand, after `/clear` for `fresh`.
