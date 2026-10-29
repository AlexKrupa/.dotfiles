# Watch: Claude Code

The runner file for Claude Code: how the session runs the watch command of the host file. The
`watchd` plugin runs `watchd wait` in the `SessionStart` and `Stop` hooks. The watch is saved in
the daemon, so it continues after a restart or `/clear`. The events come back as a system reminder.

## Start

Run the watch command of the host file in the Bash tool, with `--session "$CLAUDE_CODE_SESSION_ID"`
added. Do not change the other parts of the command. The command exits at once. The `Stop` hook of
the turn starts the wait.

## Results

- The events come as a system reminder from the `Stop` hook ("Stop hook feedback"): one JSON line
  for each event. Do the exit `0` action of `common.md`. The watch continues, so do not start it
  again.
- A `replaced` event: a different session watches the key now. Do not start the watch again.
- A text with the prefix `watchd error:`: do the exit `1` action of `common.md`.
- A rule tells you not to start the watch again, for example all MRs are merged: run the
  unsubscribe command of the host file, with `--session "$CLAUDE_CODE_SESSION_ID"` added.
- "stop watch": run the unsubscribe command of the host file, with
  `--session "$CLAUDE_CODE_SESSION_ID"` added.
