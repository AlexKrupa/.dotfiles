#!/usr/bin/env bash

set -euo pipefail

input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

if printf '%s' "$cmd" | grep -Eq '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh'; then
  deny "Blocked: piping a remote download into a shell. Download, inspect, then run."
fi

# Put each command on its own line.
segments=$(printf '%s' "$cmd" | tr ';&|' '\n')
b='[^[:alnum:]_-]'

if grep -E "(^|$b)(gh|glab)$b" <<<"$segments" | grep -E "${b}auth$b" | grep -E "${b}status($b|$)" \
  | grep -Eq "$b(--show-token|-t)($b|$)"; then
  deny "Blocked: printing the auth token. Use \`auth status\` without \`-t\`."
fi

if grep -E "(^|$b)gh$b" <<<"$segments" | grep -Eq "${b}auth${b}+token($b|$)"; then
  deny "Blocked: printing the GitHub token."
fi

if grep -E "(^|$b)git$b" <<<"$segments" | grep -Eq "${b}credential${b}+fill($b|$)"; then
  deny "Blocked: printing a git credential."
fi

if grep -E "(^|$b)security$b" <<<"$segments" | grep -E "${b}find-(generic|internet)-password($b|$)" \
  | grep -Eq "$b-[[:alpha:]]*[wg]"; then
  deny "Blocked: printing a Keychain secret. Omit \`-w\` and \`-g\`."
fi

if grep -E "(^|$b)security$b" <<<"$segments" | grep -E "${b}dump-keychain($b|$)" \
  | grep -Eq "$b-[[:alpha:]]*d"; then
  deny "Blocked: printing all Keychain secrets. Omit \`-d\`."
fi

exit 0
