#!/usr/bin/env bash
# Usage: wait.sh <hook-input.json
# Runs as a Claude Code hook (SessionStart and Stop, with asyncRewake). Runs
#   watchd wait --session "$CLAUDE_CODE_SESSION_ID" --owner-pid "$CLAUDE_PID"
# and wakes Claude when watchd gives events or an error. The binary is
# ${WATCHD:-$HOME/.local/bin/watchd}: the hook gets the PATH of Claude Code, not of the Bash tool.
# Input: the hook input JSON on stdin. For the SessionStart source `clear`, wait.sh adds
#   --rename-owner-session: after /clear, the new conversation of the same process takes the
#   watches. Any other input, no input, or input that is not JSON adds no flag.
# Writes ${TMPDIR:-/tmp}/watchd-wait/<session>.error: the last error text that woke Claude. Claude
# wakes one time for one error text. An exit 0 of watchd deletes the file.
# Output: nothing on stdout. On exit 2, stderr has the event lines of watchd, or the error text of
#   watchd with the prefix `watchd error: `. Claude Code shows the stderr text to Claude.
# Exit codes: 0 nothing to tell (no events, no watch, the session or the owner is not set, or the
#   same error text again), 2 wake Claude (the asyncRewake code)

watchd=${WATCHD:-$HOME/.local/bin/watchd}
session=${CLAUDE_CODE_SESSION_ID:-}
owner=${CLAUDE_PID:-}
[[ -n $session && -n $owner ]] || exit 0

state_dir=${TMPDIR:-/tmp}/watchd-wait
state_file=$state_dir/${session//\//_}.error

flags=()
[[ $(jq -r '.source? // empty' 2>/dev/null) == clear ]] && flags+=(--rename-owner-session)

error_file=$(mktemp) || exit 0
trap 'rm -f "$error_file"' EXIT
output=$("$watchd" wait --session "$session" --owner-pid "$owner" "${flags[@]}" 2>"$error_file")
code=$?
error=$(<"$error_file")

if [[ $code -eq 0 ]]; then
  rm -f "$state_file"
  [[ -n $output ]] || exit 0
  printf '%s\n' "$output" >&2
  exit 2
fi

[[ -n $error ]] || error="exit code $code, no message"
[[ -f $state_file && $(<"$state_file") == "$error" ]] && exit 0
mkdir -p "$state_dir"
printf '%s\n' "$error" >"$state_file"
echo "watchd error: $error" >&2
exit 2
