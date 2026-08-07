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

# build-brief only matches a gradle runner at the start of a shell segment, so any exec wrapper
# (timeout, nice, env, stdbuf, caffeinate, ...) hides it. Insert build-brief after the wrapper.
# Wrappers are not enumerated: anything is treated as one unless it is a command known to take the
# runner as a data argument instead of executing it.
if [ "$rewritten" = "$cmd" ]; then
  rewritten=$(perl -pe '
    my $data = qr/cat|bat|less|more|head|tail|wc|od|xxd|file|stat|touch|chmod|chown|ln|cp|mv|rm|
                  ls|git|diff|patch|grep|rg|ag|find|fd|sed|awk|vi|vim|nvim|nano|emacs|code|open|
                  realpath|readlink|dirname|basename|shasum|cksum|source|echo|printf|which|type|
                  brew|apt|apt-get|port|sdk/x;
    s{
      (^|[;&|]\s*)                          # segment start
      ((?:\w+=\S+\s+)*)                     # env assignments
      ((?!(?:$data)\b)                      # first word must not consume the path as data
       [^\s;&|]+(?:\s+[^\s;&|]+)*?\s+)      # the wrapper and its own args
      ([^\s;&|]*/gradlew(?:\.bat)?|gradle)  # the gradle runner
      (?=\s|$)
    }{$1$2$3build-brief $4}gx
  ' <<<"$cmd")
fi

if [ "$rewritten" = "$cmd" ]; then
  exit 0
fi

jq -nc --arg c "$rewritten" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"defer",updatedInput:{command:$c}}}'
