# Watch: Claude Code

The runner file for Claude Code: how the session runs the watch command of the host file. The
watch runs as a stream in the `Monitor` tool. The client does not exit for events. Thus a delivery
gives no "completed" message and needs no restart.

## Start

1. If the `Monitor` tool is not loaded, load it with `ToolSearch` (`select:Monitor`).
2. Start `Monitor` with these values:
   - `command`: the watch command of the host file, with `--stream` and `2>&1` added. Do not
     change the other parts of the command. The monitor sends only stdout lines. The text of exit
     `1` and `3` is on stderr.
   - `description`: `watch: <MR title>`, or `watch: hub` for the hub mode.
   - `timeout_ms`: `1800000`, the maximum.

## Results

- A notification of the monitor is one result with exit `0`: one JSON line for each event. Do the
  exit `0` action of `common.md`.
- A rule tells you to start the watch again: the stream continues. Do not start it. First do the
  checks of the rule, for example "Start" of `author.md`. If a check stops the watch, stop the
  monitor with `TaskStop`.
- A rule tells you not to start the watch again: stop the monitor with `TaskStop`.
- The monitor ended with exit `1` or `3`: do the action of that exit code in `common.md`.
- The monitor expired: start it again with the same command, with no `--fresh`. Write no reply
  text.
- "stop watch": stop the monitor with `TaskStop`, then run the unsubscribe command of the host
  file.
