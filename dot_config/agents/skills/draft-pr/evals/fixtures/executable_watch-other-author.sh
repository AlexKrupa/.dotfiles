#!/usr/bin/env bash
# Usage: watch-other-author.sh <repo-dir>
# watch-lint.sh, and anna is the author of !12 (tags-in-list), a branch above !11 in the stack.
# Tests: the lint fix of !11 needs a push of the stack, and that push changes the MR of anna. The
# session does not push and puts the fix under Needs you.
"$(dirname "$0")/watch-lint.sh" "$1"
cat >"$1.host/mr-author" <<'SH'
#!/bin/sh
# Usage: mr-author <mr-url> - prints the username of the author of the MR.
case "$1" in
  */merge_requests/12*) echo "anna" ;;
  *) echo "test-dev" ;;
esac
SH
