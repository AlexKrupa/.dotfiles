#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/herdr.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake herdr: logs each call on one line, with "|" for newlines in the arguments. Prints
# $MOCK_OUT, default {}. MOCK_FAIL=1 prints an error to stderr and exits 1. MOCK_ERROR prints its
# value to stderr and exits 1.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/herdr" <<'EOF'
#!/bin/sh
printf 'herdr %s' "$*" | tr '\n' '|' >>"$MOCK_LOG"; echo >>"$MOCK_LOG"
if [ -n "${MOCK_FAIL:-}" ]; then echo 'herdr: pane w1:p9 not found' >&2; exit 1; fi
if [ -n "${MOCK_ERROR:-}" ]; then printf '%s\n' "$MOCK_ERROR" >&2; exit 1; fi
printf '%s\n' "${MOCK_OUT:-{\}}"
EOF
chmod +x "$tmp/bin/herdr"
export PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/calls.log"

# Usage: operation NAME CALLS OUTPUT MOCK_OUT -- ARGUMENTS. Runs the script with ARGUMENTS and
# checks the herdr calls and the output.
operation() {
  local name=$1 calls=$2 output=$3 mock=$4 out code
  shift 5
  : >"$MOCK_LOG"
  out=$(MOCK_OUT=$mock "$script" "$@" 2>&1); code=$?
  check "$name: exit 0" 0 "$code"
  check "$name: herdr calls" "$calls" "$(cat "$MOCK_LOG")"
  check "$name: output" "$output" "$out"
}

operation pane-current "herdr pane current --current" "w1:p1" \
  '{"result":{"pane":{"pane_id":"w1:p1"}}}' -- pane-current

operation "pane-cwd with a foreground cwd" "herdr pane get w1:p1" "/repo/wt" \
  '{"result":{"pane":{"cwd":"/repo","foreground_cwd":"/repo/wt"}}}' -- pane-cwd w1:p1

operation "pane-cwd with no foreground cwd" "herdr pane get w1:p1" "/repo" \
  '{"result":{"pane":{"cwd":"/repo"}}}' -- pane-cwd w1:p1

operation pane-split "herdr pane split --pane w1:p1 --direction right --cwd /my repo" "w1:p2" \
  '{"result":{"pane":{"pane_id":"w1:p2"}}}' -- pane-split w1:p1 "/my repo"

operation "pane-split --focus" "herdr pane split --pane w1:p1 --direction right --cwd /r --focus" \
  "w1:p2" '{"result":{"pane":{"pane_id":"w1:p2"}}}' -- pane-split w1:p1 /r --focus

operation pane-run "herdr pane run w1:p1 echo 'a b'" "" '{}' -- pane-run w1:p1 "echo 'a b'"

operation pane-rename "herdr pane rename w1:p1 watchd board" "" '{}' \
  -- pane-rename w1:p1 "watchd board"

operation "pane-zoom on" "herdr pane zoom w1:p1 --on" "" '{}' -- pane-zoom w1:p1 on

operation "pane-zoom off" "herdr pane zoom w1:p1 --off" "" '{}' -- pane-zoom w1:p1 off

labeled_mock='{"result":{"pane":{"workspace_id":"w1"},"panes":[{"label":"a"},{"label":"watchd board"}]}}'
: >"$MOCK_LOG"
MOCK_OUT=$labeled_mock "$script" pane-labeled w1:p1 "watchd board"; code=$?
check "pane-labeled with the label: exit 0" 0 "$code"
check "pane-labeled with the label: herdr calls" \
  "herdr pane current --pane w1:p1
herdr pane list --workspace w1" "$(cat "$MOCK_LOG")"

MOCK_OUT=$labeled_mock "$script" pane-labeled w1:p1 "other"; code=$?
check "pane-labeled with no such label: exit 1" 1 "$code"

operation workspace-first-pane "herdr pane list --workspace w1" "w1:p1" \
  '{"result":{"panes":[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]}}' -- workspace-first-pane w1

operation workspace-label "herdr workspace get w1" "repo/feat" \
  '{"result":{"workspace":{"label":"repo/feat"}}}' -- workspace-label w1

operation workspace-rename "herdr workspace rename w1 repo/AB-1 feat" "" '{}' \
  -- workspace-rename w1 "repo/AB-1 feat"

operation workspace-close "herdr workspace close w1" "" '{}' -- workspace-close w1

operation "worktree-list leaves out prunable worktrees and prints an empty workspace for a closed one" \
  "herdr worktree list --cwd /repo" $'main\t/repo\tw1\nfeat\t/wt/feat\t' \
  '{"result":{"worktrees":[
    {"branch":"main","path":"/repo","open_workspace_id":"w1","is_prunable":false},
    {"branch":"feat","path":"/wt/feat","open_workspace_id":null,"is_prunable":false},
    {"branch":"gone","path":"/wt/gone","open_workspace_id":null,"is_prunable":true}]}}' \
  -- worktree-list /repo

operation worktree-open "herdr worktree open --cwd /repo --path /wt/feat --no-focus" \
  $'w2\tw2:p1' '{"result":{"workspace":{"workspace_id":"w2"},"root_pane":{"pane_id":"w2:p1"}}}' \
  -- worktree-open /repo /wt/feat

operation worktree-create "herdr worktree create --cwd /repo --branch feat/x --no-focus" \
  $'/wt/feat/x\tw2\tw2:p1' \
  '{"result":{"worktree":{"path":"/wt/feat/x"},"workspace":{"workspace_id":"w2"},"root_pane":{"pane_id":"w2:p1"}}}' \
  -- worktree-create /repo feat/x

operation agent-kind "herdr agent get w1:p1" "claude" \
  '{"result":{"agent":{"agent":"claude"}}}' -- agent-kind w1:p1

operation agent-session "herdr agent get w1:p1" "c04f" \
  '{"result":{"agent":{"agent_session":{"value":"c04f"}}}}' -- agent-session w1:p1

operation pane-read "herdr agent read w1:p1 --source recent --lines 40" "line 1
line 2" $'line 1\nline 2' -- pane-read w1:p1 40

operation agent-start "herdr agent start feat --kind claude --pane w1:p1 -- --name a b --effort high" \
  "" '{}' -- agent-start w1:p1 feat claude -- --name "a b" --effort high

operation agent-wait "herdr agent wait w1:p1 --until idle --until done --timeout 600000" "" '{}' \
  -- agent-wait w1:p1

operation agent-prompt "herdr agent prompt w1:p1 line 1|line 2" "" '{}' \
  -- agent-prompt w1:p1 $'line 1\nline 2'

operation "agent-list replaces tabs and newlines in titles with spaces" "herdr agent list" \
  $'w1:p1\tidle\t/repo\ta b c d\nw1:p2\tworking\t/wt\t' \
  '{"result":{"agents":[
    {"pane_id":"w1:p1","agent_status":"idle","cwd":"/repo","terminal_title_stripped":"a\tb\nc\rd"},
    {"pane_id":"w1:p2","agent_status":"working","cwd":"/wt","terminal_title_stripped":null}]}}' \
  -- agent-list

operation notify "herdr notification show Title --body the body --sound request" "" '{}' \
  -- notify Title "the body"

: >"$MOCK_LOG"
err=$("$script" pane-teleport w1:p1 2>&1 >/dev/null); code=$?
check "an unknown operation: exit 1" 1 "$code"
check "an unknown operation: error" "mux/herdr: unknown operation: pane-teleport" "$err"
check "an unknown operation: no herdr call" "" "$(cat "$MOCK_LOG")"

err=$(MOCK_FAIL=1 "$script" pane-current 2>&1 >/dev/null); code=$?
check "a failed herdr call: exit 1" 1 "$code"
check "a failed herdr call: herdr stderr" "herdr: pane w1:p9 not found" "$err"

err=$(MOCK_FAIL=1 "$script" pane-labeled w1:p1 x 2>&1 >/dev/null); code=$?
check "a failed herdr call in pane-labeled: exit 1" 1 "$code"
check "a failed herdr call in pane-labeled: herdr stderr" "herdr: pane w1:p9 not found" "$err"

err=$(MOCK_ERROR='{"error":{"code":"pane_not_found","message":"pane nope not found"}}' \
  "$script" pane-current 2>&1 >/dev/null); code=$?
check "a herdr JSON error: exit 1 and the message" "1 pane nope not found" "$code $err"

err=$(MOCK_ERROR='{"error":{"code":"agent_pane_busy","message":"pane is not an available shell"}}' \
  "$script" agent-start w1:p1 feat claude -- 2>&1 >/dev/null); code=$?
check "agent-start in a busy pane: exit 5 and the message" "5 pane is not an available shell" \
  "$code $err"

err=$(MOCK_ERROR='{"error":{"code":"agent_not_ready"}}' \
  "$script" agent-start w1:p1 feat claude -- 2>&1 >/dev/null); code=$?
check "agent-start with an agent that is not ready: exit 6 and the code" "6 agent_not_ready" \
  "$code $err"

exit $fail
