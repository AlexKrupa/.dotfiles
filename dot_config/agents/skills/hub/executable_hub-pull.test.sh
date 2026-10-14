#!/usr/bin/env bash
# Checks hub-pull.sh with real git repos and a fake herdr.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/hub-pull.sh"
d=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$d"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake herdr: `agent list` prints $MOCK_AGENTS.
mkdir -p "$d/bin"
cat >"$d/bin/herdr" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "agent list") cat "$MOCK_AGENTS" ;;
  *) echo "unexpected herdr call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$d/bin/herdr"
export PATH="$d/bin:$PATH" MOCK_AGENTS="$d/agents.json" XDG_STATE_HOME="$d/state"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$d/gitconfig" HERDR_PANE_ID=hub
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch dev/x

git init -q --bare "$d/origin.git"
git clone -q "$d/origin.git" "$d/seed" 2>/dev/null
git -C "$d/seed" commit -q --allow-empty -m one
git -C "$d/seed" push -q origin dev/x
git clone -q "$d/origin.git" "$d/app"
lock="$d/state/hub/app.pull.lock"

agents() { # [pane cwd]...
  local list='[]'
  while (($#)); do
    list=$(jq -c --arg p "$1" --arg c "$2" '. + [{pane_id: $p, cwd: $c}]' <<<"$list"); shift 2
  done
  echo "{\"result\": {\"agents\": $list}}" >"$MOCK_AGENTS"
}
push() { git -C "$d/seed" commit -q --allow-empty -m "$1" && git -C "$d/seed" push -q origin dev/x; }
app_head() { git -C "$d/app" rev-parse HEAD; }
new() { git -C "$d/seed" rev-parse HEAD; }
run() { # One round in the repo. Sets out and code.
  out=$(cd "$d/app" && "$script" --once 2>&1); code=$?
}

agents
run
check "up to date: exit 0, no output" "0 " "$code $out"

push two
run
check "new commit: exit 0, no output" "0 " "$code $out"
check "new commit: fast-forward" "$(new)" "$(app_head)"

push three
agents other "$d/app/src"
run
check "agent in the checkout: exit 0" 0 "$code"
check "agent in the checkout: no pull" "$(git -C "$d/seed" rev-parse HEAD~1)" "$(app_head)"

agents hub "$d/app" other "$d/app2" other2 "$d/elsewhere"
run
check "only the hub and agents outside the checkout: pull" "$(new)" "$(app_head)"

push four
git -C "$d/app" remote set-head origin --delete
run
check "no origin/HEAD: pull" "$(new)" "$(app_head)"

push five
echo x >"$d/app/file"
git -C "$d/app" add file
run
check "changes in tracked files: exit 1" 1 "$code"
check "changes in tracked files: message" \
  "hub-pull: the checkout has changes in tracked files" "$out"
git -C "$d/app" rm -q --cached file

run
check "untracked file: pull" "$(new)" "$(app_head)"
rm "$d/app/file"

push six
git -C "$d/app" switch -q -c other
run
check "other branch: exit 1" 1 "$code"
check "other branch: message" "hub-pull: the checkout is on other, not dev/x" "$out"
git -C "$d/app" switch -q dev/x

git -C "$d/app" commit -q --allow-empty -m local
run
check "no fast-forward: exit 1" 1 "$code"
check "no fast-forward: message" "hub-pull: cannot fast-forward dev/x to origin/dev/x" "$out"
git -C "$d/app" reset -q --hard HEAD~1

git -C "$d/app" remote set-url origin "$d/missing.git"
out=$(cd "$d/app" && "$script" --interval 0 2>&1); code=$?
check "5 failed fetches: exit 1" 1 "$code"
check "5 failed fetches: message" "hub-pull: git fetch origin dev/x failed" \
  "$(head -n1 <<<"$out" | cut -d: -f1-2)"
git -C "$d/app" remote set-url origin "$d/origin.git"

# An older instance runs in its loop. A new instance stops it and takes the lock.
start() { (cd "$d/app" && exec "$script" --interval 60 >/dev/null 2>"$d/$1.err") & }
lock_is() {
  for _ in $(seq 40); do [ "$(cat "$lock" 2>/dev/null)" = "$1" ] && return; sleep 0.25; done
}
start old
old=$!
lock_is "$old"
start new
new=$!
(sleep 15; kill -9 "$old") 2>/dev/null &
wait "$old"
check "older instance: exit 3" 3 "$?"
check "older instance: message" "hub-pull: replaced by a new hub pull" "$(cat "$d/old.err")"
lock_is "$new"
check "new instance: lock" "$new" "$(cat "$lock" 2>/dev/null)"
kill "$new"
wait "$new"
check "new instance stopped: lock removed" no "$([ -e "$lock" ] && echo yes || echo no)"

sleep 30 &
sleeper=$!
echo "$sleeper" >"$lock"
run
check "lock of a different program: exit 0" 0 "$code"
check "lock of a different program: not stopped" yes \
  "$(ps -p "$sleeper" >/dev/null && echo yes || echo no)"
{ kill "$sleeper"; wait "$sleeper"; } 2>/dev/null
echo 999999 >"$lock"
run
check "lock of a dead process: exit 0" 0 "$code"
check "lock removed after exit" no "$([ -e "$lock" ] && echo yes || echo no)"

out=$("$script" --repo "$d/app" --once 2>&1); code=$?
check "--repo from a different folder: exit 0" 0 "$code"

# The parent shell exits at once. The loop must stop after its next sleep.
(cd "$d/app" && bash -c '"$0" --interval 1 >/dev/null 2>"$1" & echo $! >"$2"; sleep 1' \
  "$script" "$d/orphan.err" "$d/orphan.pid")
orphan=$(cat "$d/orphan.pid")
for _ in 1 2 3 4 5 6 7 8 9 10; do ps -p "$orphan" >/dev/null || break; sleep 0.5; done
check "parent gone: process stops" no "$(ps -p "$orphan" >/dev/null && echo yes || echo no)"
check "parent gone: message" "hub-pull: the parent process is gone" \
  "$(cat "$d/orphan.err")"
kill "$orphan" 2>/dev/null

out=$("$script" --bogus 2>&1); code=$?
check "unexpected argument: exit 1" 1 "$code"
check "unexpected argument: message" "hub-pull: unexpected argument: --bogus" "$out"

exit $fail
