#!/usr/bin/env bash
# Checks worktree.sh with a real git repo and a fake herdr.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/worktree.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake herdr: logs each call. `worktree list` prints MOCK_WT_LIST, default no worktrees.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/herdr" <<'EOF2'
#!/bin/sh
printf 'herdr %s\n' "$*" >>"$MOCK_LOG"
case "$1 $2" in
  "worktree list")
    if [ -n "${MOCK_WT_LIST:-}" ]; then echo "$MOCK_WT_LIST"
    else echo '{"result":{"worktrees":[]}}'; fi ;;
  "worktree open")
    echo '{"result":{"workspace":{"workspace_id":"wO"},"root_pane":{"pane_id":"wO:p1"}}}' ;;
  "worktree create")
    echo '{"result":{"worktree":{"path":"/wt/new"},"workspace":{"workspace_id":"wN"},"root_pane":{"pane_id":"wN:p1"}}}' ;;
  *) echo "unexpected herdr call: $*" >&2; exit 2 ;;
esac
EOF2
chmod +x "$tmp/bin/herdr"
export PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/calls.log" HERDR_ENV=1
unset REX_SESSION
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
repo="$tmp/repo"
git init -q -b main "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$repo" branch feat

wt_list() { # wt_list <open workspace or null>
  printf '{"result":{"worktrees":[
    {"branch":"main","path":"%s","open_workspace_id":"w1","is_prunable":false},
    {"branch":"feat","path":"/wt/old","open_workspace_id":null,"is_prunable":true},
    {"branch":"feat","path":"/wt/feat","open_workspace_id":%s,"is_prunable":false}]}}' \
    "$repo" "$1"
}

: >"$MOCK_LOG"
out=$(MOCK_WT_LIST=$(wt_list null) "$script" feat --repo "$repo" 2>&1); code=$?
check "opens the existing worktree of a branch: exit 0" 0 "$code"
check "opens the existing worktree of a branch: output" \
  '{"path":"/wt/feat","workspace_id":"wO","root_pane_id":"wO:p1"}' "$out"
check "opens the existing worktree of a branch: herdr calls" \
  "herdr worktree list --cwd $repo
herdr worktree open --cwd $repo --path /wt/feat --no-focus" "$(cat "$MOCK_LOG")"

: >"$MOCK_LOG"
out=$(MOCK_WT_LIST=$(wt_list '"w2"') "$script" feat --repo "$repo" 2>&1); code=$?
check "prints an empty root pane when the workspace is open: exit 0" 0 "$code"
check "prints an empty root pane when the workspace is open: output" \
  '{"path":"/wt/feat","workspace_id":"w2","root_pane_id":""}' "$out"
check "prints an empty root pane when the workspace is open: herdr calls" \
  "herdr worktree list --cwd $repo" "$(cat "$MOCK_LOG")"

: >"$MOCK_LOG"
out=$("$script" feat --repo "$repo" 2>&1); code=$?
check "creates a worktree for a branch with no worktree: exit 0" 0 "$code"
check "creates a worktree for a branch with no worktree: output" \
  '{"path":"/wt/new","workspace_id":"wN","root_pane_id":"wN:p1"}' "$out"
check "creates a worktree for a branch with no worktree: herdr calls" \
  "herdr worktree list --cwd $repo
herdr worktree create --cwd $repo --branch feat --no-focus" "$(cat "$MOCK_LOG")"

: >"$MOCK_LOG"
err=$("$script" nope --repo "$repo" 2>&1 >/dev/null); code=$?
check "exits 2 for a branch that does not exist: exit 2" 2 "$code"
check "exits 2 for a branch that does not exist: error" \
  "worktree: no local branch 'nope' in $repo" "$err"
check "exits 2 for a branch that does not exist: no herdr call" "" "$(cat "$MOCK_LOG")"

err=$(env -u HERDR_ENV "$script" feat --repo "$repo" 2>&1 >/dev/null); code=$?
check "exits 4 outside a multiplexer: exit 4" 4 "$code"
check "exits 4 outside a multiplexer: error" "mux: not in herdr or Rex" "$err"

exit $fail
