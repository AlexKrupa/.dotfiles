#!/usr/bin/env bash
# UserPromptSubmit hook.
# Adds a style instruction to each prompt, unless the prompt ends with "noterse".

input=$(cat)

if [[ "$input" =~ noterse([[:space:]]|\\n|\\r|\\t)*\" ]]; then
  echo '{}'
  exit 0
fi

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "respond tersely in ASD-STE100 Simplified Technical English"
  }
}
JSON
