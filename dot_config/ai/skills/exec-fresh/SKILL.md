---
name: exec-fresh
description: >-
  Use when the user runs /exec-fresh after a superpowers:writing-plans handoff, to execute the
  plan in a cleared Claude session in the same herdr pane.
argument-hint: "[subagent|native] [low|medium|high|xhigh|max]"
disable-model-invocation: true
---

# exec-fresh

Executes a superpowers plan in a fresh session. After this turn, a detached script clears this
Claude session, sets the effort, and submits the superpowers execution command with the plan path.
The user runs this skill in place of a reply to the writing-plans handoff. This means that the
user approved the plan.

Input: `$ARGUMENTS` can contain a mode (`subagent` or `native`) and an effort level. Both are
optional.

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
   2. The plan and the code that it touches fit in one session with space left: `native`.
      Estimate the size from the plan. Do not read the code for this. The fresh session starts
      with only the plan in its context, so `native` can run a longer plan than the planning
      session assumed.
   3. Else: `subagent`.
3. Effort, if `$ARGUMENTS` has no effort. The plan did the design, so the executor needs less
   reasoning:
   - `medium`: each step is exact. It gives the full code, or a mechanical edit at a named
     location, and the commands.
   - `high`: some steps leave design choices open, or need investigation or debugging.
   - Do not pick `low`: a failing test needs reasoning. Do not pick `xhigh` or `max`: the plan
     already contains the design.
4. Run the script:

   ```sh
   ~/.claude/skills/exec-fresh/exec-fresh.sh <subagent|native> <effort> '<plan path>'
   ```

5. Report the result, then end the turn. The script waits until the turn ends, so the turn has no
   more tool calls after the report.
   - Exit `0`: the stdout line, then one line per decision: "Mode: <mode> - <how>." and
     "Effort: <effort> - <how>." For mode, `<how>` is "from the argument", "kept, <reason>",
     "changed from <recommended mode>, <reason>", or "no recommendation, <reason>". For effort,
     `<how>` is "from the argument" or "<reason>". Each reason is one sentence. Then: "This
     session clears after this turn. Do not type in this pane until the plan command shows. The
     effort stays set for later sessions of this model: `/effort auto` resets it."
   - Exit `1`: the stderr text, word for word.

If the plan command does not show, the log is `${TMPDIR:-/tmp}/exec-fresh.log`. The user can type
`/clear`, then send the command by hand.
