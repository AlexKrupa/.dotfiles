#!/usr/bin/env bash
# Checks ticket-id-rename.sh with scratch repos, git-spice, and a fake herdr. No LLM.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/ticket-id-rename.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Global config enables 1Password commit signing, which fails headless.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null HOME="$tmp/home"
export GIT_AUTHOR_NAME="Test Dev" GIT_AUTHOR_EMAIL=dev@example.com
export GIT_COMMITTER_NAME="Test Dev" GIT_COMMITTER_EMAIL=dev@example.com
mkdir -p "$HOME"
unset HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID

# new_repo <name>: sets $repo to a repo with git-spice on main. main has a TODO(AB-0) of other
# work and an AB-01 id that only looks like the placeholder.
new_repo() {
  repo="$tmp/$1"
  mkdir -p "$repo" && git -C "$repo" init -q -b main
  commit m.txt $'TODO(AB-0) main\nAB-01 main' Init
  git-spice -C "$repo" repo init --trunk main >/dev/null 2>&1
}
# branch <name> <base>: creates <name> on <base>, tracked by git-spice.
branch() {
  git -C "$repo" switch -q -c "$1" "$2"
  git-spice -C "$repo" branch track "$1" --base "$2" >/dev/null 2>&1
}
# commit <file> <content> <message>
commit() { printf '%s\n' "$2" >"$repo/$1"; git -C "$repo" add -A; git -C "$repo" commit -q -m "$3"; }
run() { (cd "$repo" && "$script" "$@") >"$tmp/out" 2>"$tmp/err"; }
branches() { git -C "$repo" branch --format='%(refname:short)' | paste -sd, -; }
messages() { git -C "$repo" log --reverse --format=%B "$1" | sed '/^$/d' | paste -sd, -; }
show() { git -C "$repo" show "$1"; }
stack() { git-spice -C "$repo" log short --all --json | jq -c "select(.name == \"$1\")"; }

# feat_repo <name>: new_repo, then the current branch AB-0/feat with 2 commits.
feat_repo() {
  new_repo "$1"
  branch AB-0/feat main
  commit f.txt $'one TODO(AB-0)\nAB-01 keep' "AB-0: add f"
  commit f.txt $'one TODO(AB-0)\nAB-01 keep\ntwo AB-0' $'AB-0: edit f\n\nBody AB-0.'
}

# --- guards ---

feat_repo guards
git -C "$repo" switch -q main
run AB-0 AB-17; code=$?
check "current branch without placeholder: exit 1" 1 "$code"
check "current branch without placeholder: message" \
  "main does not start with AB-0/" "$(cat "$tmp/err")"
git -C "$repo" switch -q AB-0/feat

echo dirty >>"$repo/f.txt"
run AB-0 AB-17; code=$?
check "dirty worktree: exit 1" 1 "$code"
check "dirty worktree: branch stays" "AB-0/feat,main" "$(branches)"
git -C "$repo" checkout -q f.txt

git -C "$repo" branch AB-17/feat main
run AB-0 AB-17; code=$?
check "new name exists: exit 1" 1 "$code"
check "new name exists: message" "branch AB-17/feat exists" "$(cat "$tmp/err")"
git -C "$repo" branch -q -D AB-17/feat

# --- one branch ---

feat_repo one
date_before=$(git -C "$repo" log -1 --format=%ad)
run AB-0 AB-17; code=$?
check "one: exit 0" 0 "$code"
check "one: branch renamed" "AB-17/feat,main" "$(branches)"
check "one: messages" "AB-17: add f,AB-17: edit f,Body AB-17." "$(messages main..HEAD)"
check "one: added lines in the last commit" \
  $'one TODO(AB-17)\nAB-01 keep\ntwo AB-17' "$(show HEAD:f.txt)"
check "one: added lines in the first commit" $'one TODO(AB-17)\nAB-01 keep' "$(show HEAD~:f.txt)"
check "one: main lines stay" $'TODO(AB-0) main\nAB-01 main' "$(show HEAD:m.txt)"
check "one: main stays" "Init" "$(messages main)"
check "one: worktree files follow" $'one TODO(AB-17)\nAB-01 keep\ntwo AB-17' "$(cat "$repo/f.txt")"
check "one: clean worktree" "" "$(git -C "$repo" status --porcelain)"
check "one: author date stays" "$date_before" "$(git -C "$repo" log -1 --format=%ad)"
check "one: git-spice tracks it" '{"name":"AB-17/feat","current":true,"down":{"name":"main"}}' \
  "$(stack AB-17/feat)"
check "one: report" "branch: AB-0/feat -> AB-17/feat" "$(grep '^branch:' "$tmp/out")"

# --- pushed ---

feat_repo pushed
git init -q --bare -b main "$tmp/pushed.git"
git -C "$repo" remote add origin "$tmp/pushed.git"
git -C "$repo" push -q origin main
git -C "$repo" push -q -u origin AB-0/feat
remote_heads() { git -C "$repo" ls-remote --heads origin | sed 's#.*refs/heads/##' | paste -sd, -; }

run AB-0 AB-17; code=$?
check "pushed, no --push: exit 2" 2 "$code"
check "pushed, no --push: report" "pushed: AB-0/feat origin/AB-0/feat" "$(cat "$tmp/out")"
check "pushed, no --push: branch stays" "AB-0/feat,main" "$(branches)"
check "pushed, no --push: remote stays" "AB-0/feat,main" "$(remote_heads)"

run AB-0 AB-17 --push; code=$?
check "pushed, --push: exit 0" 0 "$code"
check "pushed, --push: remote renamed" "AB-17/feat,main" "$(remote_heads)"
check "pushed, --push: upstream" "origin/AB-17/feat" \
  "$(git -C "$repo" rev-parse --abbrev-ref '@{upstream}')"
check "pushed, --push: remote has the new commits" "$(git -C "$repo" rev-parse HEAD)" \
  "$(git -C "$repo" rev-parse origin/AB-17/feat)"
check "pushed, --push: report" "pushed: AB-17/feat (deleted origin/AB-0/feat)" \
  "$(grep '^pushed:' "$tmp/out")"

# --- a chain of 2 branches, and a branch above it ---

new_repo chain
branch AB-0/base main
commit b.txt "TODO(AB-0) base" "AB-0: base"
branch AB-0/top AB-0/base
commit t.txt "TODO(AB-0) top" "AB-0: top"
branch other AB-0/top
commit o.txt "TODO(AB-0) other" "AB-9: other"
git -C "$repo" switch -q AB-0/top

run AB-0 AB-17 AB-0/top AB-0/base; code=$?
check "chain: exit 0" 0 "$code"
check "chain: both renamed" "AB-17/base,AB-17/top,main,other" "$(branches)"
check "chain: messages" "AB-17: base,AB-17: top" "$(messages main..AB-17/top)"
check "chain: lower branch lines in the upper branch" "TODO(AB-17) base" "$(show AB-17/top:b.txt)"
check "chain: git-spice stack" \
  '{"name":"AB-17/top","current":true,"down":{"name":"AB-17/base"},"ups":[{"name":"other"}]}' \
  "$(stack AB-17/top)"
check "chain: branch above restacked" '{"name":"other","down":{"name":"AB-17/top"}}' \
  "$(stack other)"
check "chain: branch above keeps its own lines" "TODO(AB-0) other" "$(show other:o.txt)"
check "chain: branch above gets the new lines" "TODO(AB-17) top" "$(show other:t.txt)"
check "chain: report" "restacked: other" "$(grep '^restacked:' "$tmp/out")"

new_repo split
branch AB-0/a main
commit a.txt a "AB-0: a"
branch AB-0/b main
commit b.txt b "AB-0: b"
run AB-0 AB-17 AB-0/a AB-0/b; code=$?
check "not one chain: exit 1" 1 "$code"
check "not one chain: message" "AB-0/a AB-0/b are not one git-spice stack chain" "$(cat "$tmp/err")"

# --- herdr ---

# Fake herdr: logs each call. The worktree of AB-0/feat is open in workspace w9.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/herdr" <<'EOF'
#!/bin/sh
echo "herdr $*" >>"$MOCK_LOG"
case "$1 $2" in
  "worktree list") echo '{"result":{"worktrees":[{"branch":"AB-0/feat","open_workspace_id":"w9"}]}}' ;;
  "workspace get") echo '{"result":{"workspace":{"label":"AB-0/feat"}}}' ;;
  "pane current") echo '{"result":{"pane":{"pane_id":"w9:p1"}}}' ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$tmp/bin/herdr"

feat_repo herdr
(cd "$repo" && PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/herdr.log" HERDR_ENV=1 \
  HERDR_AFTER_TURN_SLEEP=0 "$script" AB-0 AB-17 --title 'Add `f` for $HOME') \
  >"$tmp/out" 2>"$tmp/err"; code=$?
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q '^herdr agent prompt' "$tmp/herdr.log" && break
  sleep 0.5
done
check "herdr: exit 0" 0 "$code"
check "herdr: workspace renamed" "herdr workspace rename w9 AB-17/feat" \
  "$(grep '^herdr workspace rename' "$tmp/herdr.log")"
check "herdr: session renamed after the turn" "herdr agent prompt w9:p1 /rename [AB-17] Add \`f\` for \$HOME" \
  "$(grep '^herdr agent prompt' "$tmp/herdr.log")"
check "herdr: report" "session: queued /rename [AB-17] Add \`f\` for \$HOME" \
  "$(grep '^session:' "$tmp/out")"

feat_repo no-herdr
run AB-0 AB-17 --title 'Add f'
check "no herdr: report" "session: manual /rename [AB-17] Add f" "$(grep '^session:' "$tmp/out")"

exit "$fail"
