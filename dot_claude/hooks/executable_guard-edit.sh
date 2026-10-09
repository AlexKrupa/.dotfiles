#!/usr/bin/env bash

# Blocks file tools in build output and generated code.
# A deny rule like `Edit(**/build/**)` also blocks Bash `rm` in these paths.

set -euo pipefail

path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')

if [[ $path =~ (^|/)(build|generated)/ ]]; then
  jq -nc --arg r "Blocked: editing build output or generated code (\`$path\`). Change the source instead." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi

exit 0
