#!/usr/bin/env bash
# Usage: context.sh <hook-input.json
# Runs as a Claude Code hook (SessionStart with the matcher `compact`, not async). After a
# compaction, it reminds Claude of the watches of the session:
#   watchd watches --session "$CLAUDE_CODE_SESSION_ID"
# The binary is ${WATCHD:-$HOME/.local/bin/watchd}: the hook gets the PATH of Claude Code.
# Output: on stdout, the SessionStart JSON with `additionalContext`: the watches, the runner file,
#   and the error rule. Nothing if the session has no watch, the session is not set, or watchd
#   fails: a reminder is not necessary for the watch to continue.
# Exit codes: 0 always

watchd=${WATCHD:-$HOME/.local/bin/watchd}
session=${CLAUDE_CODE_SESSION_ID:-}
[[ -n $session ]] || exit 0

watches=$("$watchd" watches --session "$session" 2>/dev/null) || exit 0
[[ -n $watches ]] || exit 0

here=$(cd "$(dirname "$0")" && pwd)
context="This session has watchd watches. They continue after the compaction: do not start them again.
Each line is the mode, the repo, and the MRs (- is all MRs of the worktree):
$watches
Follow the rules of $here/watch-runner.md.
After a text with the prefix \`watchd error:\`, do not start a watch again, unless the text tells you to run the watch command again."
jq -n --arg context "$context" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}}'
