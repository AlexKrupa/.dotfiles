#!/usr/bin/env bash

set -euo pipefail

input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")

# A missing binary is a config problem, not a per-command one: warn once per session on any
# Bash call rather than waiting for a Gradle command to surface it.
if ! command -v build-brief >/dev/null 2>&1; then
  session=$(jq -r '.session_id // "unknown"' <<<"$input")
  marker="${TMPDIR:-/tmp}/claude-build-brief-missing-${session//[^A-Za-z0-9_-]/_}"
  if [ ! -e "$marker" ]; then
    : >"$marker"
    jq -nc '{systemMessage:"build-brief not found on PATH - Gradle runs unfiltered. Install: brew install static-var/tap/build-brief"}'
  fi
  exit 0
fi

# --stop/--version produce no build output, so the reducer would report a fabricated status.
case "$cmd" in
  "" | *build-brief* | *--stop* | *--version*) exit 0 ;;
esac

rewritten=$(build-brief rewrite "$cmd" 2>/dev/null) || exit 0
if [ "$rewritten" = "$cmd" ]; then
  exit 0
fi

jq -nc --arg c "$rewritten" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"defer",updatedInput:{command:$c}}}'
