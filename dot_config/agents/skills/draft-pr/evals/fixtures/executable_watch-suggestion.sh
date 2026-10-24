#!/usr/bin/env bash
# Usage: watch-suggestion.sh <repo-dir>
# watch-stack.sh with no job logs. The prompt gives a suggestion comment with no code.
# Tests: the reply shows the probable change as code, and no write on the host.
"$(dirname "$0")/watch-stack.sh" "$1"
