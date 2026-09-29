#!/usr/bin/env bash
# Checks hub-watch-gitlab.sh with a real git repo and a fake glab.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/hub-watch-gitlab.sh"
d=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$d"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake glab: `api <path>` prints $MOCK_DIR/<fixture>.json. If the file does not exist, it prints
# {} for an MR, {"approved_by": []} for approvals, and [] for a list.
# MOCK_FAIL is a path pattern: a matching call writes $MOCK_FAIL_MSG on stderr and fails.
# MOCK_NOAUTH=1 makes `auth status` fail.
mkdir -p "$d/bin" "$d/mock"
cat >"$d/bin/glab" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_LOG"
if [ "$1" = auth ]; then [ -z "${MOCK_NOAUTH:-}" ]; exit; fi
[ "$1" = api ] || { echo "unexpected glab call: $*" >&2; exit 2; }
if [ -n "${MOCK_FAIL:-}" ]; then
  case "$2" in $MOCK_FAIL) echo "$MOCK_FAIL_MSG" >&2; exit 1 ;; esac
fi
iid=$(echo "$2" | cut -d/ -f4 | cut -d'?' -f1)
case "$2" in
  user) f=user ;;
  projects/group%2Fsub%2Fapp) f=project ;;
  todos\?*) f=todos ;;
  projects/7/merge_requests\?author_username=*) f=mine ;;
  users/1/events\?*) f=events ;;
  projects/7/merge_requests\?*) f=commented ;;
  projects/7/merge_requests/*/approvals) f=approvals_$iid ;;
  projects/7/merge_requests/*/notes\?*) f=notes_$iid ;;
  projects/7/merge_requests/*) f=mr_$iid ;;
  *) echo "unexpected glab api path: $2" >&2; exit 2 ;;
esac
if [ -f "$MOCK_DIR/$f.json" ]; then cat "$MOCK_DIR/$f.json"; exit; fi
case "$f" in
  mr_*) echo '{}' ;;
  approvals_*) echo '{"approved_by": []}' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$d/bin/glab"
export PATH="$d/bin:$PATH" MOCK_LOG="$d/calls.log" MOCK_DIR="$d/mock" XDG_STATE_HOME="$d/state"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$d/gitconfig"
git config --global init.defaultBranch main

git init -q "$d/app"
git -C "$d/app" remote add origin https://gitlab.example.com/group/sub/app.git
echo '{"id": 1, "username": "me"}' >"$d/mock/user.json"
echo '{"id": 7}' >"$d/mock/project.json"
state="$d/state/hub/app.json"
lock="$d/state/hub/app.lock"
url=https://gitlab.example.com/group/sub/app/-/merge_requests

fixture() { printf '%s\n' "$2" >"$d/mock/$1.json"; }
run() { # One check in the repo. Sets out, err, and code.
  out=$(cd "$d/app" && "$script" --once 2>"$d/err"); code=$?; err=$(cat "$d/err")
}

run
check "first check: exit 0" 0 "$code"
check "first check: no events" "" "$out"
check "first check: state saved" '[]' "$(jq -c .todos "$state")"
check "lock removed after exit" no "$([ -e "$lock" ] && echo yes || echo no)"

fixture todos '[{"id": 11, "action_name": "review_requested", "author": {"username": "anna"},
  "target": {"iid": 5, "title": "Add foo", "source_branch": "ABC-1/foo"},
  "target_url": "'"$url"'/5"}]'
run
check "new to-do item" \
  '{"kind":"todo","iid":5,"title":"Add foo","url":"'"$url"'/5","actor":"anna","detail":"review_requested","branch":"ABC-1/foo"}' \
  "$out"
run
check "same to-do item: no events" "" "$out"

export MOCK_FAIL='todos*' MOCK_FAIL_MSG='glab: 403 Forbidden (HTTP 403)'
run
check "HTTP 403: exit 1" 1 "$code"
check "HTTP 403: message" \
  "hub-watch-gitlab: HTTP 403 on todos?project_id=7&type=MergeRequest&state=pending&per_page=100. The token needs the read_api scope." \
  "$err"

export MOCK_FAIL_MSG='dial tcp: connection refused'
: >"$MOCK_LOG"
out=$(cd "$d/app" && "$script" --interval 0 2>"$d/err"); code=$?
check "5 network errors: exit 1" 1 "$code"
check "5 network errors: 5 tries" 5 "$(grep -c '^api todos' "$MOCK_LOG")"
check "5 network errors: message" \
  "hub-watch-gitlab: todos?project_id=7&type=MergeRequest&state=pending&per_page=100: dial tcp: connection refused" \
  "$(cat "$d/err")"
unset MOCK_FAIL MOCK_FAIL_MSG

sleep 30 &
sleeper=$!
echo "$sleeper" >"$lock"
run
check "lock of a live process: exit 1" 1 "$code"
check "lock of a live process: message" \
  "hub-watch-gitlab: hub watch already runs for this repo (PID $sleeper)" "$err"
{ kill "$sleeper"; wait "$sleeper"; } 2>/dev/null
echo 999999 >"$lock"
run
check "lock of a dead process: exit 0" 0 "$code"

export MOCK_NOAUTH=1
run
check "glab not authenticated: exit 1" 1 "$code"
check "glab not authenticated: message" \
  "hub-watch-gitlab: glab is not authenticated, run: glab auth login" "$err"
unset MOCK_NOAUTH

git init -q "$d/app2"
git -C "$d/app2" remote add origin git@gitlab.example.com:group/sub/app.git
out=$(cd "$d/app2" && "$script" --once 2>&1); code=$?
check "scp-style SSH remote: same project" "0 " "$code $out"

exit $fail
