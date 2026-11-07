#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/rex.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake rex: logs each call on one line, with "|" for newlines in the arguments. Prints
# $MOCK_OUT, default {}. MOCK_FAIL=1 prints an error to stderr and exits 3, as rex does.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/rex" <<'EOF'
#!/bin/sh
printf 'rex %s' "$*" | tr '\n' '|' >>"$MOCK_LOG"; echo >>"$MOCK_LOG"
if [ -n "${MOCK_FAIL:-}" ]; then echo 'Error: block target "b9" not found' >&2; exit 3; fi
if [ -n "${MOCK_OUT:-}" ]; then printf '%s\n' "$MOCK_OUT"; else echo '{}'; fi
EOF
chmod +x "$tmp/bin/rex"
unset REX_BIN_DIR
export PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/calls.log" REX_SESSION=s1 REX_BLOCK=b1 \
  XDG_STATE_HOME=$tmp/state

# Usage: operation NAME CALLS OUTPUT MOCK_OUT -- ARGUMENTS. Runs the script with ARGUMENTS and
# checks the rex calls and the output.
operation() {
  local name=$1 calls=$2 output=$3 mock=$4 out code
  shift 5
  : >"$MOCK_LOG"
  out=$(MOCK_OUT=$mock "$script" "$@" 2>&1); code=$?
  check "$name: exit 0" 0 "$code"
  check "$name: rex calls" "$calls" "$(cat "$MOCK_LOG")"
  check "$name: output" "$output" "$out"
}

operation pane-current "" "b1" '{}' -- pane-current

operation "pane-cwd with a foreground process" "rex block call -b b1 process" "/repo/wt" \
  '{"foreground":{"name":"claude","cwd":"/repo/wt"}}' -- pane-cwd b1

operation "pane-cwd with no foreground cwd decodes the reported directory" \
  "rex block call -b b1 process
rex block call -b b1 pwd" "/my repo/50%" \
  '{"foreground":null,"pwd":"file://host.local/my%20repo/50%25"}' -- pane-cwd b1

operation pane-split "rex split -b b1 --split right --cwd /my repo --focus=false --json" "b2" \
  '{"anchor_id":"b1","block_ids":["b2"]}' -- pane-split b1 "/my repo"

operation "pane-split --focus" "rex split -b b1 --split right --cwd /r --focus=true --json" "b2" \
  '{"anchor_id":"b1","block_ids":["b2"]}' -- pane-split b1 /r --focus

operation pane-run "rex block call -b b1 pwd
rex send -b b1 echo 'a b'
rex send-key -b b1 enter" "" '{"pwd":"file://host/repo"}' -- pane-run b1 "echo 'a b'"

operation pane-read "rex capture -b b1 --trim --unwrap" $'c\nd' $'a\nb\nc\nd' -- pane-read b1 2

operation pane-rename "rex block rename b1 watchd board" "" '{}' -- pane-rename b1 "watchd board"

operation "pane-zoom on" "rex zoom -b b1 --on" "" '{}' -- pane-zoom b1 on

operation "pane-zoom off" "rex zoom -b b1 --off" "" '{}' -- pane-zoom b1 off

labeled_mock='{"session_id":"s2","blocks":[{"block_id":"b1","label":"shell"},{"block_id":"b2","label":"watchd board"}]}'
: >"$MOCK_LOG"
MOCK_OUT=$labeled_mock "$script" pane-labeled b1 "watchd board"; code=$?
check "pane-labeled with the label: exit 0" 0 "$code"
check "pane-labeled with the label: rex calls" \
  "rex block inspect b1 --json
rex block ls -s s2 --json" "$(cat "$MOCK_LOG")"

MOCK_OUT=$labeled_mock "$script" pane-labeled b1 "other"; code=$?
check "pane-labeled with no such label: exit 1" 1 "$code"

operation workspace-first-pane "rex session inspect s2 --json" "b5" \
  '{"windows":[{"layers":[{"blocks":[{"block_id":"b5"},{"block_id":"b6"}]}]},{"layers":[{"blocks":[{"block_id":"b7"}]}]}]}' \
  -- workspace-first-pane s2

operation workspace-label "rex session inspect s2 --json" "repo/feat" '{"label":"repo/feat"}' \
  -- workspace-label s2

operation workspace-rename "rex session rename s2 repo/AB-1 feat" "" '{}' \
  -- workspace-rename s2 "repo/AB-1 feat"

operation workspace-close "rex session kill s2" "" '{}' -- workspace-close s2

# The notification goes to the terminal, so `script` gives the script a terminal. The terminal
# also echoes the end of stdin.
out=$(script -q /dev/null "$script" notify "Title" $'the\tbody\nline' </dev/null \
  | perl -0ne 'print $1 if /(\e\]9;[^\a]*\a)/')
check "notify: OSC 9 with title and body on the terminal" $'\e]9;Title: the body line\a' "$out"

for name in pane-teleport; do
  : >"$MOCK_LOG"
  err=$("$script" "$name" b1 2>&1 >/dev/null); code=$?
  check "$name: exit 1" 1 "$code"
  check "$name: error" "mux/rex: unknown operation: $name" "$err"
  check "$name: no rex call" "" "$(cat "$MOCK_LOG")"
done

err=$(MOCK_FAIL=1 "$script" workspace-label s2 2>&1 >/dev/null); code=$?
check "a failed rex call: exit 1" 1 "$code"
check "a failed rex call: rex stderr" 'Error: block target "b9" not found' "$err"

err=$(MOCK_FAIL=1 "$script" pane-labeled b1 x 2>&1 >/dev/null); code=$?
check "a failed rex call in pane-labeled: exit 1" 1 "$code"
check "a failed rex call in pane-labeled: rex stderr" 'Error: block target "b9" not found' "$err"


# Agent operations. A second fake rex answers from files in $MOCK_DIR:
# - blocks.<session>: the output of `block ls -s <session> --json`
# - <block>.<method>: the output of `block call -b <block> <method>`, default {}
# - <block>.gone: each `block call -b <block>` fails, as for a block that `block ls` still lists
# - events: the lines of `rex events` after its client_connected line. Then the stream stays open.
# `ls --json` prints $MOCK_SESSIONS. `block inspect` gives the session s1. `new` gives the
# session s9 with the block b9.
mock=$tmp/mock
mkdir -p "$mock"
cat >"$tmp/bin/rex" <<'EOF'
#!/bin/bash
printf 'rex %s' "$*" | tr '\n' '|' >>"$MOCK_LOG"; echo >>"$MOCK_LOG"
if [ "$1" = --autostart=false ]; then shift; fi
case "$1 $2" in
  "ls --json") printf '%s\n' "$MOCK_SESSIONS" ;;
  "block inspect") echo '{"session_id":"s1"}' ;;
  "block ls") cat "$MOCK_DIR/blocks.$4" ;;
  "block call")
    if [ -f "$MOCK_DIR/$4.gone" ]; then echo "Error: block target \"$4\" not found" >&2; exit 3; fi
    if [ -f "$MOCK_DIR/$4.$5" ]; then cat "$MOCK_DIR/$4.$5"; else echo '{}'; fi ;;
  "events -s") echo '{"type":"client_connected"}'; cat "$MOCK_DIR/events" 2>/dev/null; exec sleep 30 ;;
  "new "*) echo '{"session_id":"s9","initial_windows":[{"window_id":"w9","block_ids":["b9"]}]}' ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$tmp/bin/rex"
export MOCK_DIR=$mock

event() { # event <block> <state>: one program_status_changed line of `rex events --json`
  printf '{"type":"session_event","payload":{"session_id":"s1","event":{"type":"block_event","payload":{"block_id":"%s","creator_name":"com.superlogical.terminal","name":"program_status_changed","payload":{"id":"","record":{"state":"%s"},"reason":"report"}}}}}\n' "$1" "$2"
}
status() { # status <state>: a program_status result
  printf '{"records":[{"state":"%s","app":"claude-code","effective_app":"claude-code"}]}\n' "$1"
}
reset_mock() { rm -f "$mock"/*; : >"$MOCK_LOG"; }

reset_mock
status idle >"$mock/b1.program_status"
echo '{"foreground":{"name":"claude","cwd":"/repo"}}' >"$mock/b1.process"
out=$("$script" agent-kind b1 2>&1); code=$?
check "agent-kind gives the name of the foreground program: exit 0" 0 "$code"
check "agent-kind gives the name of the foreground program: output" "claude" "$out"

reset_mock
echo '{"records":[]}' >"$mock/b1.program_status"
echo '{"foreground":{"name":"fish","cwd":"/repo"}}' >"$mock/b1.process"
out=$("$script" agent-kind b1 2>&1); code=$?
check "agent-kind with no program status is empty: exit 0" 0 "$code"
check "agent-kind with no program status is empty: output" "" "$out"

reset_mock
err=$("$script" agent-session b1 2>&1 >/dev/null); code=$?
check "agent-session exits 1" 1 "$code"
check "agent-session: error" "mux/rex: agent sessions are not supported" "$err"

reset_mock
echo '{"pwd":"file://host/repo"}' >"$mock/b1.pwd"
echo '{"records":[]}' >"$mock/b1.program_status"
(sleep 1; status idle >"$mock/b1.program_status") &
out=$(MUX_AGENT_START_SECONDS=10 "$script" agent-start b1 feat claude -- --name "[AB-1] it's x" \
  --effort high 2>&1); code=$?
check "agent-start waits until the agent reports a status: exit 0" 0 "$code"
check "agent-start: label, command, enter, then the status" \
  "rex block rename b1 claude: feat
rex send -b b1 'claude' '--name' '[AB-1] it'\"'\"'s x' '--effort' 'high'
rex send-key -b b1 enter" "$(grep -v -e program_status -e ' pwd$' "$MOCK_LOG")"
check "agent-start: reads the status until it has a record" yes \
  "$([ "$(grep -c program_status "$MOCK_LOG")" -ge 2 ] && echo yes || echo no)"

# Each argument comes back unchanged from a parse in fish and in a POSIX shell.
reset_mock
echo '{"pwd":"file://host/repo"}' >"$mock/b1.pwd"
status idle >"$mock/b1.program_status"
args=("it's" 'x\' 'a\\b' '\'"'"'$(echo INJECTED)"\'"'" '$HOME (echo S) `echo T`')
"$script" agent-start b1 feat printf -- '[%s]' "${args[@]}"
sent=$(sed -n 's/^rex send -b b1 //p' "$MOCK_LOG")
expected=$(printf '[%s]' "${args[@]}")
check "agent-start quotes the arguments for sh" "$expected" "$(sh -c "$sent" 2>&1)"
if command -v fish >/dev/null; then
  check "agent-start quotes the arguments for fish" "$expected" "$(fish --no-config -c "$sent" 2>&1)"
fi

reset_mock
echo '{"pwd":"file://host/repo"}' >"$mock/b1.pwd"
echo '{"records":[]}' >"$mock/b1.program_status"
err=$(MUX_AGENT_START_SECONDS=1 "$script" agent-start b1 feat claude -- 2>&1 >/dev/null); code=$?
check "agent-start with no status after the timeout: exit 6" 6 "$code"
check "agent-start with no status after the timeout: error" \
  "mux/rex: the agent in b1 reported no status in 1 s" "$err"

reset_mock
(sleep 1; echo '{"pwd":"file://host/repo"}' >"$mock/b2.pwd") &
SECONDS=0
"$script" pane-run b2 'exec tuicr'; code=$?
check "pane-run waits until the shell of a new pane reports its directory: exit 0" 0 "$code"
check "pane-run waits until the shell of a new pane reports its directory: send after the wait" \
  "yes rex send -b b2 exec tuicr" \
  "$([ "$SECONDS" -ge 1 ] && echo yes || echo no) $(grep '^rex send ' "$MOCK_LOG")"

reset_mock
SECONDS=0
MUX_PANE_READY_SECONDS=1 "$script" pane-run b2 'ls'; code=$?
check "pane-run sends after the wait also with no reported directory: exit 0" 0 "$code"
check "pane-run sends after the wait also with no reported directory: send" "rex send -b b2 ls" \
  "$(grep '^rex send ' "$MOCK_LOG")"

reset_mock
status idle >"$mock/b1.program_status"
out=$("$script" agent-prompt b1 $'line 1\nline 2\e[201~' 2>&1); code=$?
check "agent-prompt pastes the text with no ESC, then presses enter: exit 0" 0 "$code"
check "agent-prompt pastes the text with no ESC, then presses enter: rex calls" \
  "$(printf 'rex block call -b b1 program_status\nrex send -b b1 \033[200~line 1|line 2[201~\033[201~\nrex send-key -b b1 enter')" \
  "$(cat "$MOCK_LOG")"

reset_mock
echo '{"records":[]}' >"$mock/b1.program_status"
err=$("$script" agent-prompt b1 hi 2>&1 >/dev/null); code=$?
check "agent-prompt in a pane with no agent: exit 1 and no send" "1 mux/rex: no agent in b1 0" \
  "$code $err $(grep -c '^rex send' "$MOCK_LOG")"

reset_mock
status blocked >"$mock/b1.program_status"
err=$("$script" agent-prompt b1 hi 2>&1 >/dev/null); code=$?
check "agent-prompt to a blocked agent: exit 1 and no send" \
  "1 mux/rex: the agent in b1 waits for an answer 0" "$code $err $(grep -c '^rex send' "$MOCK_LOG")"

reset_mock
status idle >"$mock/b1.program_status"
SECONDS=0
MUX_AGENT_WAIT_SECONDS=20 "$script" agent-wait b1; code=$?
check "agent-wait returns at once when the agent is idle: exit 0" 0 "$code"
check "agent-wait returns at once when the agent is idle: time" yes \
  "$([ "$SECONDS" -lt 5 ] && echo yes || echo no)"

reset_mock
status working >"$mock/b1.program_status"
{ event b1 working; event b1 blocked; event b1 done; } >"$mock/events"
SECONDS=0
MUX_AGENT_WAIT_SECONDS=20 "$script" agent-wait b1; code=$?
check "agent-wait returns on a done event for the pane: exit 0" 0 "$code"
check "agent-wait returns on a done event for the pane: time" yes \
  "$([ "$SECONDS" -lt 5 ] && echo yes || echo no)"
check "agent-wait: events of the session of the pane" "rex events -s s1 --json" \
  "$(grep '^rex events' "$MOCK_LOG")"

reset_mock
status working >"$mock/b1.program_status"
{ event b2 idle; event b2 done; } >"$mock/events"
SECONDS=0
MUX_AGENT_WAIT_SECONDS=2 "$script" agent-wait b1 2>/dev/null; code=$?
check "agent-wait ignores events of other panes: exit 1" 1 "$code"

reset_mock
status working >"$mock/b1.program_status"
err=$(MUX_AGENT_WAIT_SECONDS=1 "$script" agent-wait b1 2>&1); code=$?
check "agent-wait exits 1 after the timeout: exit 1" 1 "$code"
check "agent-wait exits 1 after the timeout: error" \
  "mux/rex: the agent in b1 did not end its turn in 1 s" "$err"

reset_mock
export MOCK_SESSIONS='{"sessions":[{"session_id":"s1"},{"session_id":"s2"}]}'
echo '{"blocks":[{"block_id":"b1"},{"block_id":"b2"}]}' >"$mock/blocks.s1"
echo '{"blocks":[{"block_id":"b3"},{"block_id":"b4"}]}' >"$mock/blocks.s2"
: >"$mock/b4.gone"
status working >"$mock/b1.program_status"
echo '{"foreground":{"name":"claude","cwd":"/repo"}}' >"$mock/b1.process"
printf '{"title":"a\\tb\\nc\\rd"}\n' >"$mock/b1.title"
echo '{"records":[]}' >"$mock/b2.program_status"
status idle >"$mock/b3.program_status"
echo '{"foreground":null}' >"$mock/b3.process"
echo '{"pwd":"file://host/wt/feat"}' >"$mock/b3.pwd"
out=$("$script" agent-list 2>&1); code=$?
check "agent-list replaces tabs and newlines in titles with spaces: exit 0" 0 "$code"
check "agent-list replaces tabs and newlines in titles with spaces, skips a gone block: output" \
  $'b1\tworking\t/repo\ta b c d\nb3\tidle\t/wt/feat\t' "$out"

out=$("$script" repo-pane /wt 2>&1); code=$?
check "repo-pane finds a block in the folder or below it, skips a gone block" "0 b3" "$code $out"
check "repo-pane does not start a Rex server" yes \
  "$(grep -q '^rex --autostart=false ls --json$' "$MOCK_LOG" && echo yes || echo no)"

"$script" repo-pane /nothing >/dev/null 2>&1; code=$?
check "repo-pane with no block in the folder: exit 1" 1 "$code"

out=$(env -u REX_BLOCK MUX_PANE=b7 "$script" pane-current 2>&1)
check "pane-current with MUX_PANE and no REX_BLOCK" b7 "$out"


# Worktree operations, with a real git repo. The repo name is the folder name of the main worktree.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null MUX_WORKTREE_ROOT=$tmp/worktrees
repo=$tmp/my-repo
git init -q -b main "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$repo" branch feat

reset_mock
export MOCK_SESSIONS='{"sessions":[{"session_id":"s1","label":"other"}]}'
out=$("$script" worktree-create "$repo" feat 2>&1); code=$?
check "worktree-create adds the worktree under the worktree root and opens a session: exit 0" 0 "$code"
check "worktree-create adds the worktree under the worktree root and opens a session: output" \
  $'$tmp/worktrees/my-repo/feat\ts9\tb9' "${out//$tmp/\$tmp}"
check "worktree-create: the worktree has the branch" feat \
  "$(git -C "$tmp/worktrees/my-repo/feat" branch --show-current 2>&1)"
check "worktree-create: rex calls" "rex new my-repo/feat --cwd $tmp/worktrees/my-repo/feat --json
rex ls --json" "$(cat "$MOCK_LOG")"

reset_mock
out=$("$script" worktree-create "$repo" AB-1/new-thing 2>&1); code=$?
check "worktree-create keeps a slash in the branch in the path and the label: exit 0" 0 "$code"
check "worktree-create keeps a slash in the branch in the path and the label: output" \
  $'$tmp/worktrees/my-repo/AB-1/new-thing\ts9\tb9' "${out//$tmp/\$tmp}"
check "worktree-create makes a new branch from HEAD" AB-1/new-thing \
  "$(git -C "$tmp/worktrees/my-repo/AB-1/new-thing" branch --show-current 2>&1)"
check "worktree-create keeps a slash in the branch: label" \
  "rex new my-repo/AB-1/new-thing --cwd $tmp/worktrees/my-repo/AB-1/new-thing --json" \
  "$(grep '^rex new' "$MOCK_LOG")"

reset_mock
export MOCK_SESSIONS='{"sessions":[{"session_id":"s1","label":"my-repo"},{"session_id":"s2","label":"x"}]}'
out=$("$script" worktree-open "$repo" "$tmp/worktrees/my-repo/feat" 2>&1); code=$?
check "worktree-open moves the session after the repo session: exit 0" 0 "$code"
check "worktree-open moves the session after the repo session: output" $'s9\tb9' "$out"
check "worktree-open moves the session after the repo session: rex calls" \
  "rex new my-repo/feat --cwd $tmp/worktrees/my-repo/feat --json
rex ls --json
rex session move s9 --after s1" "$(cat "$MOCK_LOG")"

git -C "$repo" branch gone
git -C "$repo" worktree add -q "$tmp/worktrees/my-repo/gone" gone
rm -rf "$tmp/worktrees/my-repo/gone"
reset_mock
export MOCK_SESSIONS='{"sessions":[{"session_id":"s1","label":"my-repo"},{"session_id":"s3","label":"my-repo/feat"}]}'
out=$("$script" worktree-list "$repo" 2>&1); code=$?
check "worktree-list prints the session of an open worktree: exit 0" 0 "$code"
check "worktree-list prints the session of an open worktree and of the main checkout, no prunable worktree: output" \
  $'main\t$tmp/my-repo\ts1\nAB-1/new-thing\t$tmp/worktrees/my-repo/AB-1/new-thing\t\nfeat\t$tmp/worktrees/my-repo/feat\ts3' \
  "${out//$tmp/\$tmp}"

out=$("$script" worktree-list "$tmp/worktrees/my-repo/feat" 2>&1); code=$?
check "worktree-list from a linked worktree: the same repo name" \
  $'main\t$tmp/my-repo\ts1\nAB-1/new-thing\t$tmp/worktrees/my-repo/AB-1/new-thing\t\nfeat\t$tmp/worktrees/my-repo/feat\ts3' \
  "${out//$tmp/\$tmp}"

reset_mock
export MOCK_SESSIONS='{"sessions":[{"session_id":"s1","label":"renamed-repo"},{"session_id":"s9","label":"tidy-otter"}]}'
out=$("$script" worktree-list "$repo" 2>&1); code=$?
check "worktree-list finds a renamed session by the session that worktree-open made" \
  $'main\t$tmp/my-repo\t\nAB-1/new-thing\t$tmp/worktrees/my-repo/AB-1/new-thing\ts9\nfeat\t$tmp/worktrees/my-repo/feat\ts9' \
  "${out//$tmp/\$tmp}"

export MOCK_SESSIONS='{"sessions":[{"session_id":"s1","label":"my-repo"}]}'
out=$("$script" worktree-list "$repo" 2>&1); code=$?
check "worktree-list leaves out a session that is gone" \
  $'main\t$tmp/my-repo\ts1\nAB-1/new-thing\t$tmp/worktrees/my-repo/AB-1/new-thing\t\nfeat\t$tmp/worktrees/my-repo/feat\t' \
  "${out//$tmp/\$tmp}"

err=$("$script" worktree-create "$repo" feat 2>&1 >/dev/null); code=$?
check "worktree-create of a branch with a worktree: exit 1" 1 "$code"
check "worktree-create of a branch with a worktree: git error" yes \
  "$(grep -q "already" <<<"$err" && echo yes || echo no)"

exit $fail
