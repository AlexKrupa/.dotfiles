#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# The script runs the mux.sh in its own folder, so the copy gets a fake beside it. The fake logs
# each call on one line. pane-split gives the pane S. agent-prompt writes the text to
# $MOCK_PROMPT, or with MOCK_PROMPT_FAIL prints it to stderr and exits 1. pane-current gives
# $MOCK_PANE, and fails when it is empty.
mkdir -p "$tmp/script" "$tmp/bin" "$tmp/tuicr-bin"
cp "$here/tuicr.sh" "$tmp/script/tuicr.sh"
script=$tmp/script/tuicr.sh
cat >"$tmp/script/mux.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_LOG"
case $1 in
  pane-cwd) echo /cwd ;;
  pane-split) echo S ;;
  pane-current) [ -n "${MOCK_PANE:-}" ] || { echo "mux: not in herdr or Rex" >&2; exit 4; }
    echo "$MOCK_PANE" ;;
  agent-prompt)
    if [ -n "${MOCK_PROMPT_FAIL:-}" ]; then echo "$MOCK_PROMPT_FAIL" >&2; exit 1; fi
    printf '%s' "$3" >"$MOCK_PROMPT" ;;
esac
EOF
chmod +x "$tmp/script/mux.sh"

# `tuicr review comments` prints $MOCK_COMMENTS. The tuicr of a pane is a symlink to sleep with
# the name tuicr, because `send` finds it with `pgrep -x tuicr`. macOS kills a copy of sleep.
cat >"$tmp/bin/tuicr" <<'EOF'
#!/bin/sh
printf '%s\n' "$MOCK_COMMENTS"
EOF
chmod +x "$tmp/bin/tuicr"
ln -s /bin/sleep "$tmp/tuicr-bin/tuicr"

export PATH="$tmp/bin:$PATH" HOME=$tmp/home TMPDIR=$tmp/t XDG_STATE_HOME=$tmp/state \
  MOCK_LOG=$tmp/calls.log MOCK_PROMPT=$tmp/prompt
mkdir -p "$TMPDIR" "$HOME/Library/Application Support/tuicr/reviews" "$tmp/repo"

# Usage: branch_pane PANE AGENT. Makes the state dir of a `branch` pane with a live tuicr child.
branch_pane() {
  local dir=$TMPDIR/tuicr-panes/$1
  "$tmp/tuicr-bin/tuicr" 30 &
  local tuicr_pid=$!
  mkdir -p "$dir"
  printf '%s\n' "$2" >"$dir/agent"
  printf '%s\n' "$tmp/repo" >"$dir/repo"
  printf '%s\n' "$$" >"$dir/pid"
  printf '{"sessions":[{"pid":%s,"slug":"s1"}]}\n' "$tuicr_pid" \
    >"$HOME/Library/Application Support/tuicr/reviews/active_sessions.json"
}

: >"$MOCK_LOG"
"$script" branch A; code=$?
check "branch opens a zoomed tuicr pane next to the active pane" "0
pane-cwd A
pane-split A /cwd --focus
pane-run S exec '$script' pane 'A'
pane-zoom S on" "$code
$(cat "$MOCK_LOG")"

: >"$MOCK_LOG"
"$script" mr A; code=$?
check "mr opens the target selector, not zoomed" "0
pane-cwd A
pane-split A /cwd --focus
pane-run S exec tuicr" "$code
$(cat "$MOCK_LOG")"

mkdir -p "$TMPDIR/tuicr-panes/other"
: >"$MOCK_LOG"
"$script" pane A </dev/null 2>/dev/null; code=$?
check "pane with no pane ID: exit 1, the state of other panes stays" "1 yes" \
  "$code $([ -d "$TMPDIR/tuicr-panes/other" ] && echo yes || echo no)"

branch_pane B A
export MOCK_COMMENTS='[{"id":"c1","location":"review","content":"Fix it"}]'
: >"$MOCK_LOG"
"$script" send B; code=$?
check "send gives the new comments to the agent, then unzooms the pane: exit 0" 0 "$code"
check "send gives the new comments to the agent, then unzooms the pane: calls" \
  "agent-prompt A I reviewed your code and have the following comments. Please address them.

1. Fix it
pane-zoom B off" "$(cat "$MOCK_LOG")"

rm -f "$MOCK_PROMPT"
: >"$MOCK_LOG"
"$script" send B; code=$?
check "send of comments that were sent before: no prompt" "0 no" \
  "$code $([ -f "$MOCK_PROMPT" ] && echo yes || echo no)"

export MOCK_COMMENTS='[{"id":"c1","location":"review","content":"Fix it"},{"id":"c2","location":"a.kt:3","content":"Rename"}]'
: >"$MOCK_LOG"
err=$(MOCK_PROMPT_FAIL="mux/rex: no agent in A" "$script" send B 2>&1); code=$?
check "a failed send: exit 1 and the error on stderr" \
  "1 tuicr comments not sent: mux/rex: no agent in A" "$code $err"
check "a failed send: a notification with the error" \
  "notify tuicr comments not sent mux/rex: no agent in A" "$(grep '^notify' "$MOCK_LOG")"

: >"$MOCK_LOG"
"$script" send B; code=$?
check "after a failed send, the next send gives the comment again" "0
1. \`a.kt:3\` - Rename" "$code
$(sed -n '$p' "$MOCK_PROMPT")"

exit $fail
