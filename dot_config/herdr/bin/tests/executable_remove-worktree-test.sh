#!/bin/sh
# Uses a temporary repository and a fake herdr that runs `git worktree remove`.
bin=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
  GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
repo=$tmp/repo
wt=$tmp/wt
# herdr can store a path with a symlink in it. git prints the resolved path.
ln -s "$tmp" "$tmp/link"

# herdr: `workspace get` prints the worktree workspace w1. `worktree remove` runs git, then makes
# the checkout writable again if MOCK_UNLOCK is set, like a Gradle daemon that stops. The other
# calls go to $MOCK_LOG, one argument for each line.
cat >"$tmp/herdr" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "workspace get")
    printf '{"result":{"workspace":{"label":"wt","worktree":{"repo_root":"%s","checkout_path":"%s"}}}}' \
      "$repo" "$tmp/link/wt" ;;
  "worktree remove")
    shift 4
    out=\$(git -C "$repo" worktree remove "\$@" "$tmp/link/wt" 2>&1)
    code=\$?
    [ -n "\${MOCK_UNLOCK:-}" ] && chmod -R u+w "$wt"
    [ "\$code" -eq 0 ] || { jq -n --arg m "\$out" '{error: {message: \$m}}' >&2; exit 1; }
    ;;
  *) printf '%s\n' "\$@" >>"\$MOCK_LOG" ;;
esac
EOF
chmod +x "$tmp/herdr"
export HERDR_BIN_PATH=$tmp/herdr HERDR_ACTIVE_WORKSPACE_ID=w1 MOCK_LOG=$tmp/calls.log

git init -q -b main "$repo"
git -C "$repo" commit -q --allow-empty -m base

# setup [untracked|locked]: a new worktree, with an untracked file or a folder git cannot delete
setup() {
  : >"$MOCK_LOG"
  [ -d "$wt" ] && chmod -R u+w "$wt" && rm -rf "$wt"
  git -C "$repo" worktree prune
  git -C "$repo" branch -q -D b 2>/dev/null
  git -C "$repo" worktree add -q "$wt" -b b
  case ${1:-} in
    untracked) : >"$wt/new.txt" ;;
    locked) mkdir -p "$wt/.gradle/x" && : >"$wt/.gradle/x/f" && chmod 555 "$wt/.gradle/x" ;;
  esac
}
listed() { git -C "$repo" worktree list --porcelain | grep -qx "worktree $wt" && echo yes || echo no; }
exists() { [ -e "$wt" ] && echo yes || echo no; }
kept="Branch b kept: origin/HEAD is not set"

setup
"$bin/remove-worktree.sh"
check "removes a clean worktree" "no no" "$(listed) $(exists)"
check "a clean removal shows the toast" "notification
show
Worktree removed
--body
wt
$kept" "$(cat "$MOCK_LOG")"

setup untracked
"$bin/remove-worktree.sh"
check "keeps a worktree with changes" "yes yes" "$(listed) $(exists)"
check "a refusal shows the error and keeps the workspace" "notification
show
Worktree not removed: wt
--body
fatal: '$tmp/link/wt' contains modified or untracked files, use --force to delete it
--sound
request" "$(cat "$MOCK_LOG")"

setup locked
MOCK_UNLOCK=1 "$bin/remove-worktree.sh" --force
check "deletes the folder that git left" "no no" "$(listed) $(exists)"
check "a left folder closes the workspace and shows the toast" "workspace
close
w1
notification
show
Worktree removed
--body
wt
$kept" "$(cat "$MOCK_LOG")"

setup locked
"$bin/remove-worktree.sh" --force
check "a folder that stays is not listed" "no yes" "$(listed) $(exists)"
check "a folder that stays is in the toast" "workspace
close
w1
notification
show
Worktree removed
--body
wt
Folder not deleted: $tmp/link/wt
$kept" "$(cat "$MOCK_LOG")"

exit "$fail"
