#!/usr/bin/env bash
# Usage: watch-comments.sh <repo-dir>
# watch-stack.sh with no job logs. The prompt gives a comment, a reaction, and an approval.
# Tests: an assessment in the reply, and no reply, reaction, or other write on the host.
"$(dirname "$0")/watch-stack.sh" "$1"
