#!/usr/bin/env bash
# Checks hub-status.sh with a real git repo and a fake herdr.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/hub-status.sh"
d=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$d"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake herdr: `agent list` prints $MOCK_AGENTS. MOCK_FAIL=1 makes it fail.
mkdir -p "$d/bin"
cat >"$d/bin/herdr" <<'EOF'
#!/bin/sh
printf 'herdr %s\n' "$*" >>"$MOCK_LOG"
[ -z "${MOCK_FAIL:-}" ] || exit 1
case "$1 $2" in
  "agent list") cat "$MOCK_AGENTS" ;;
  *) echo "unexpected herdr call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$d/bin/herdr"
export PATH="$d/bin:$PATH" MOCK_LOG="$d/calls.log" MOCK_AGENTS="$d/agents.json"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$d/gitconfig"
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main

git init -q "$d/work"
git -C "$d/work" commit -q --allow-empty -m one
git -C "$d/work" worktree add -q "$d/wt-a" -b ABC-1/a
git -C "$d/work" worktree add -q "$d/wt-b" -b ABC-2/b
mkdir -p "$d/wt-b/src" "$d/wt-a2" "$d/elsewhere"
git init -q "$d/solo"
git -C "$d/solo" commit -q --allow-empty -m one

agent() { # pane status cwd title
  jq -n --arg p "$1" --arg s "$2" --arg c "$3" --arg t "$4" \
    '{pane_id: $p, agent_status: $s, cwd: $c, terminal_title_stripped: $t}'
}
{
  agent wA:p1 working "$d/wt-a" $'Fix\tthe\nbug'
  agent wB:p1 idle "$d/wt-b/src" ""
  agent wM:p1 idle "$d/work" "hub"
  agent wP:p1 working "$d/wt-a2" "prefix trap"
  agent wX:p1 working "$d/elsewhere" "other repo"
  echo '{"pane_id": "wN:p1", "agent_status": "idle", "cwd": null}'
} | jq -s '{result: {agents: .}}' >"$MOCK_AGENTS"

out=$(cd "$d/work" && "$script"); code=$?
check "exit 0" 0 "$code"
check "agent in a linked worktree" $'wA:p1\tworking\tABC-1/a\t'"$d/wt-a"$'\tFix the bug' \
  "$(sed -n 1p <<<"$out")"
check "agent in a worktree subfolder, empty title" $'wB:p1\tidle\tABC-2/b\t'"$d/wt-b/src"$'\t' \
  "$(sed -n 2p <<<"$out")"
check "no main checkout, prefix, or other-repo agents" 2 "$(wc -l <<<"$out" | tr -d ' ')"

out=$("$script" --repo "$d/wt-a"); code=$?
check "--repo from a linked worktree: same agents" "wA:p1 wB:p1" \
  "$(cut -f1 <<<"$out" | tr '\n' ' ' | sed 's/ $//')"

: >"$MOCK_LOG"
out=$("$script" --repo "$d/solo"); code=$?
check "no linked worktrees: exit 0" 0 "$code"
check "no linked worktrees: no output" "" "$out"
check "no linked worktrees: no herdr call" "" "$(cat "$MOCK_LOG")"

echo '{"result":{"agents":[]}}' >"$MOCK_AGENTS"
out=$("$script" --repo "$d/work"); code=$?
check "no agents: exit 0" 0 "$code"
check "no agents: no output" "" "$out"

out=$(MOCK_FAIL=1 "$script" --repo "$d/work" 2>&1); code=$?
check "herdr fails: exit 1" 1 "$code"
check "herdr fails: message" "hub-status: herdr agent list failed" "$out"

out=$("$script" --repo "$d/elsewhere" 2>&1); code=$?
check "not a repo: exit 1" 1 "$code"

exit $fail
