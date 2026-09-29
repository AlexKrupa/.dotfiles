#!/usr/bin/env bash
# Checks work-start.sh with real git repos, the real shared bin/ scripts, and fake herdr, glab,
# git-spice, and work-next.sh.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/work-start.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake herdr: answers the calls work-start.sh makes and logs each call. MOCK_START_FAIL is the
# error text of a failed `agent start`. MOCK_WT_LIST is the output of `worktree list`.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/herdr" <<'EOF'
#!/bin/sh
printf 'herdr %s\n' "$*" >>"$MOCK_LOG"
case "$1 $2" in
  "worktree create")
    echo '{"result":{"worktree":{"path":"/wt/path"},' \
      '"workspace":{"workspace_id":"wT","label":"wt-label"},' \
      '"root_pane":{"pane_id":"wT:p1"}}}' ;;
  "worktree list")
    if [ -n "${MOCK_WT_LIST:-}" ]; then echo "$MOCK_WT_LIST"
    else echo '{"result":{"worktrees":[]}}'; fi ;;
  "worktree open")
    echo '{"result":{"workspace":{"workspace_id":"wO"},"root_pane":{"pane_id":"wO:p1"}}}' ;;
  "agent start")
    if [ -n "${MOCK_START_FAIL:-}" ]; then echo "$MOCK_START_FAIL" >&2; exit 1; fi
    echo '{}' ;;
  "agent prompt")
    printf '%s' "$4" >"$MOCK_PROMPT"; echo '{}' ;;
  "pane current")
    echo '{"result":{"pane":{"pane_id":"wL:p1"}}}' ;;
  *) echo "unexpected herdr call: $*" >&2; exit 2 ;;
esac
EOF
# Fake git-spice: logs each call. `branch create <name>` checks out a new branch, as git-spice
# does. MOCK_SPICE_FAIL is the error text of a failed call.
cat >"$tmp/bin/git-spice" <<'EOF'
#!/bin/sh
printf 'git-spice %s\n' "$*" >>"$MOCK_LOG"
if [ -n "${MOCK_SPICE_FAIL:-}" ]; then echo "$MOCK_SPICE_FAIL" >&2; exit 1; fi
if [ "$1 $2" = "branch create" ]; then git switch -q -c "$3"; fi
EOF
# Fake work-next.sh: writes its arguments and stdin to $MOCK_NEXT.
cat >"$tmp/bin/work-next" <<'EOF'
#!/bin/sh
{ printf '%s\n' "$@"; cat; } >"$MOCK_NEXT.part" && mv "$MOCK_NEXT.part" "$MOCK_NEXT"
EOF
# Fake glab: fetch-gitlab-mr.sh needs it on PATH. The fetch subcommand makes no glab call.
cat >"$tmp/bin/glab" <<'EOF'
#!/bin/sh
echo "unexpected glab call: $*" >&2; exit 2
EOF
chmod +x "$tmp/bin/herdr" "$tmp/bin/git-spice" "$tmp/bin/work-next" "$tmp/bin/glab"
export PATH="$tmp/bin:$PATH" WORK_NEXT="$tmp/bin/work-next" TMPDIR="$tmp" HERDR_ENV=1
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --global user.name tester
git config --global user.email tester@example.com
git config --global init.defaultBranch main

# fresh [default branch]: a new repo whose local default branch (main if not given) is one commit
# behind origin, with git-spice set up. Sets $d and $work.
n=0
fresh() {
  local b=${1:-main}
  n=$((n + 1))
  d="$tmp/case$n"
  git init -q --bare -b "$b" "$d/remote.git"
  git init -q -b "$b" "$d/work"
  git -C "$d/work" commit -q --allow-empty -m one
  git -C "$d/work" remote add origin "$d/remote.git"
  git -C "$d/work" push -q -u origin "$b"
  git clone -q "$d/remote.git" "$d/other"
  git -C "$d/other" commit -q --allow-empty -m two
  git -C "$d/other" push -q origin "$b"
  git -C "$d/work" update-ref refs/spice/data HEAD
  work="$d/work"
  export MOCK_LOG="$d/calls.log" MOCK_PROMPT="$d/prompt.txt" MOCK_NEXT="$d/next.txt"
  : >"$MOCK_LOG"
}

# run <stdin> <args...>: runs work-start.sh in ${cwd:-$work}. Sets $out, $err, $code.
run() {
  local input=$1; shift
  out=$(cd "${cwd:-$work}" && printf '%s' "$input" | "$script" "$@" 2>"$tmp/err") \
    && code=0 || code=$?
  err=$(cat "$tmp/err")
}

has_branch() {
  git -C "$work" show-ref --verify --quiet "refs/heads/$1" && echo yes || echo no
}

# push_branch <branch>: pushes one more commit on <branch> to origin from the other clone.
push_branch() {
  git -C "$d/other" switch -q "$1" 2>/dev/null || git -C "$d/other" switch -q -c "$1"
  git -C "$d/other" commit -q --allow-empty -m "$1"
  git -C "$d/other" push -q origin "$1"
}

remote_tip() { git -C "$d/remote.git" rev-parse "refs/heads/$1"; }

# wait_next: waits up to 5 s for the fake work-next.sh, then prints what it got.
wait_next() {
  for _ in $(seq 50); do [ -f "$MOCK_NEXT" ] && break; sleep 0.1; done
  cat "$MOCK_NEXT" 2>/dev/null
}

# Mode.
fresh
git -C "$work" worktree add -q "$d/linked" -b ABC-1/old
run '' mode
check "mode: main checkout is new" new "$out"
cwd="$d/linked" run '' mode
check "mode: linked worktree is next" next "$out"

# New mode, default base: main after a fast-forward.
fresh
run 'ABC-0 fix the typo' ABC-0 'Fix README typo!'
check "new: exit 0" 0 "$code"
check "new: branch name from the slug" "ABC-0/fix-readme-typo" "$(jq -r .branch <<<"$out")"
check "new: main is fast-forwarded to origin/main" \
  "$(git -C "$work" rev-parse origin/main)" "$(git -C "$work" rev-parse main)"
check "new: the branch starts at main" \
  "$(git -C "$work" rev-parse main)" "$(git -C "$work" rev-parse ABC-0/fix-readme-typo)"
check "new: mode, base, tracked" "new main true" \
  "$(jq -r '"\(.mode) \(.base) \(.tracked)"' <<<"$out")"
check "new: git-spice tracks the branch on main" \
  "git-spice -C $work branch track ABC-0/fix-readme-typo --base main" \
  "$(grep '^git-spice' "$MOCK_LOG")"
check "new: worktree opened from the main checkout" \
  "herdr worktree create --cwd $work --branch ABC-0/fix-readme-typo --no-focus" \
  "$(grep '^herdr worktree create' "$MOCK_LOG")"
check "new: agent started with no claude flags" \
  "herdr agent start abc-0-fix-readme-typo --kind claude --pane wT:p1" \
  "$(grep '^herdr agent start' "$MOCK_LOG")"
check "new: prompt from stdin" "ABC-0 fix the typo" "$(cat "$MOCK_PROMPT")"
check "new: output has pane, worktree, and agent" "wT:p1 /wt/path abc-0-fix-readme-typo" \
  "$(jq -r '"\(.pane_id) \(.worktree) \(.agent)"' <<<"$out")"
check "new: main checkout stays on main" main "$(git -C "$work" branch --show-current)"

# New mode, default base: a default branch that is not main.
fresh dev/x
run 'ABC-0 fix it' ABC-0 'Fix it'
check "default branch dev/x: exit 0" 0 "$code"
check "default branch dev/x: fast-forward to origin/dev/x" \
  "$(git -C "$work" rev-parse origin/dev/x)" "$(git -C "$work" rev-parse dev/x)"
check "default branch dev/x: base and tracked" "dev/x true" \
  "$(jq -r '"\(.base) \(.tracked)"' <<<"$out")"
check "default branch dev/x: git-spice base" \
  "git-spice -C $work branch track ABC-0/fix-it --base dev/x" "$(grep '^git-spice' "$MOCK_LOG")"

# Claude flags, symbols in the slug text, a multi-line prompt with shell characters.
fresh
run $'ABC-7\n\nFix `x` in "$HOME" dir' ABC-7 'Add: --base support (v2)' \
  -- --model opus --effort high
check "flags: slug drops symbols" "ABC-7/add-base-support-v2" "$(jq -r .branch <<<"$out")"
check "flags: claude flags passed" \
  "herdr agent start abc-7-add-base-support-v2 --kind claude --pane wT:p1 -- --model opus \
--effort high" \
  "$(grep '^herdr agent start' "$MOCK_LOG")"
check "flags: prompt arrives with no changes" $'ABC-7\n\nFix `x` in "$HOME" dir' \
  "$(cat "$MOCK_PROMPT")"

# Long slug text.
fresh
run p ABC-8 'Implement the new payment provider integration for checkout'
check "long: slug cut at a word end" "ABC-8/implement-the-new-payment-provider" \
  "$(jq -r .branch <<<"$out")"
check "long: agent name cut at a word end" "abc-8-implement-the-new-payment" \
  "$(jq -r .agent <<<"$out")"

# Bad input.
fresh
run p ABC-9 '!!!'
check "no slug: exit 1" 1 "$code"
run '' ABC-9 'typo'
check "no prompt: exit 1" 1 "$code"
check "bad input: no herdr call" "" "$(cat "$MOCK_LOG")"

# Branch exists.
fresh
run p ABC-0 'typo'
run p ABC-0 'typo'
check "exists: exit 1" 1 "$code"
check "exists: message names the branch" "work-start: branch exists: ABC-0/typo" "$err"

# No git-spice setup.
fresh
git -C "$work" update-ref -d refs/spice/data
run p ABC-0 'typo'
check "no git-spice: exit 1" 1 "$code"
check "no git-spice: message" \
  "work-start: git-spice is not set up: run 'gs repo init' first" "$err"
check "no git-spice: no branch" no "$(has_branch ABC-0/typo)"

# main diverged from origin/main.
fresh
git -C "$work" commit -q --allow-empty -m local
before=$(git -C "$work" rev-parse main)
run p ABC-0 'typo'
check "diverged: exit 1" 1 "$code"
check "diverged: main unchanged" "$before" "$(git -C "$work" rev-parse main)"
check "diverged: no branch" no "$(has_branch ABC-0/typo)"
check "diverged: no herdr call" "" "$(cat "$MOCK_LOG")"

# Untracked file in the main checkout.
fresh
echo notes >"$work/notes.txt"
run p ABC-0 'typo'
check "untracked file: exit 0" 0 "$code"
check "untracked file: main is fast-forwarded" \
  "$(git -C "$work" rev-parse origin/main)" "$(git -C "$work" rev-parse main)"

# Remote base: no fast-forward, no tracking.
fresh
before=$(git -C "$work" rev-parse main)
run p ABC-0 'typo' --base origin/main
check "remote base: exit 0" 0 "$code"
check "remote base: not tracked" "origin/main false" \
  "$(jq -r '"\(.base) \(.tracked)"' <<<"$out")"
check "remote base: no git-spice call" "" "$(grep '^git-spice' "$MOCK_LOG")"
check "remote base: main not moved" "$before" "$(git -C "$work" rev-parse main)"
check "remote base: branch starts at origin/main" \
  "$(git -C "$work" rev-parse origin/main)" "$(git -C "$work" rev-parse ABC-0/typo)"

# Local base: not permitted in new mode.
fresh
git -C "$work" branch ABC-0/first
run p ABC-0 'second' --base ABC-0/first
check "local base: exit 1" 1 "$code"
check "local base: no branch" no "$(has_branch ABC-0/second)"

# Base does not exist.
fresh
run p ABC-0 'typo' --base origin/nope
check "no base: exit 1" 1 "$code"
check "no base: no branch" no "$(has_branch ABC-0/typo)"

# git-spice track fails.
fresh
MOCK_SPICE_FAIL=1 run p ABC-0 'typo'
check "track fails: exit 2" 2 "$code"
check "track fails: branch stays" yes "$(has_branch ABC-0/typo)"
check "track fails: message names the step" \
  "work-start: git-spice branch track failed (branch ABC-0/typo stays)" "$err"

# Agent not ready.
fresh
MOCK_START_FAIL='{"error":{"code":"agent_not_ready"}}' run p ABC-0 'typo'
check "not ready: exit 3" 3 "$code"
check "not ready: message has the pane id" \
  "work-start: agent not ready in pane wT:p1 (branch ABC-0/typo stays)" "$err"
check "not ready: no prompt" "" "$(grep '^herdr agent prompt' "$MOCK_LOG")"

# Other start failure.
fresh
MOCK_START_FAIL='boom' run p ABC-0 'typo'
check "start fails: exit 2" 2 "$code"

# Next mode: a stacked branch in the same worktree, then work-next.sh.
fresh
git -C "$work" worktree add -q "$d/linked" -b ABC-1/old
cwd="$d/linked" run $'ABC-2\n\nFix `x` in "$HOME"' ABC-2 'Second part'
check "next: exit 0" 0 "$code"
check "next: mode, branch, base" "next ABC-2/second-part ABC-1/old" \
  "$(jq -r '"\(.mode) \(.branch) \(.base)"' <<<"$out")"
check "next: git-spice creates the branch" \
  "git-spice branch create ABC-2/second-part --no-commit" "$(grep '^git-spice' "$MOCK_LOG")"
check "next: worktree now on the new branch" ABC-2/second-part \
  "$(git -C "$d/linked" branch --show-current)"
check "next: work-next.sh gets pane, old branch, and prompt" \
  $'wL:p1\nABC-1/old\nABC-2\n\nFix `x` in "$HOME"' "$(wait_next)"
check "next: no worktree create" "" "$(grep '^herdr worktree create' "$MOCK_LOG")"
check "next: main checkout stays on main" main "$(git -C "$work" branch --show-current)"

# Next mode with changes in the worktree. The 5 s wait for work-next.sh is expected here.
fresh
git -C "$work" worktree add -q "$d/linked" -b ABC-1/old
echo draft >"$d/linked/draft.txt"
cwd="$d/linked" run p ABC-2 'Second part'
check "next dirty: exit 1" 1 "$code"
check "next dirty: message" "work-start: the worktree has changes: the old work is not done" "$err"
check "next dirty: no branch" no "$(has_branch ABC-2/second-part)"
check "next dirty: no work-next.sh" "" "$(wait_next)"

# Next mode with --base or claude flags.
fresh
git -C "$work" worktree add -q "$d/linked" -b ABC-1/old
cwd="$d/linked" run p ABC-2 'Second part' --base origin/main
check "next --base: exit 1" 1 "$code"
cwd="$d/linked" run p ABC-2 'Second part' -- --model opus
check "next flags: exit 1" 1 "$code"
check "next bad options: no branch" no "$(has_branch ABC-2/second-part)"

# Next mode on a branch that git-spice does not track.
fresh
git -C "$work" worktree add -q "$d/linked" -b ABC-1/old
MOCK_SPICE_FAIL='FTL git-spice: branch not tracked: ABC-1/old' \
  cwd="$d/linked" run p ABC-2 'Second part'
check "next untracked: exit 1" 1 "$code"
check "next untracked: message has the git-spice error" \
  "work-start: git-spice branch create failed: FTL git-spice: branch not tracked: ABC-1/old" "$err"

# Existing branch only on origin: a local branch at the remote tip, in a new workspace.
fresh
push_branch ABC-5/review-me
before=$(git -C "$work" rev-parse main)
run $'ABC-5\n\nReview it' ABC-5 --branch ABC-5/review-me
check "existing: exit 0" 0 "$code"
check "existing: mode, branch, base, tracked" "existing ABC-5/review-me null false" \
  "$(jq -r '"\(.mode) \(.branch) \(.base) \(.tracked)"' <<<"$out")"
check "existing: local branch at the remote tip" \
  "$(remote_tip ABC-5/review-me)" "$(git -C "$work" rev-parse ABC-5/review-me)"
check "existing: worktree opened for the branch" \
  "herdr worktree create --cwd $work --branch ABC-5/review-me --no-focus" \
  "$(grep '^herdr worktree create' "$MOCK_LOG")"
check "existing: agent started in the root pane" \
  "herdr agent start abc-5-review-me --kind claude --pane wT:p1" \
  "$(grep '^herdr agent start' "$MOCK_LOG")"
check "existing: prompt from stdin" $'ABC-5\n\nReview it' "$(cat "$MOCK_PROMPT")"
check "existing: output has pane, worktree, and workspace" "wT:p1 /wt/path wT" \
  "$(jq -r '"\(.pane_id) \(.worktree) \(.workspace_id)"' <<<"$out")"
check "existing: no git-spice call" "" "$(grep '^git-spice' "$MOCK_LOG")"
check "existing: main not moved" "$before" "$(git -C "$work" rev-parse main)"
check "existing: main checkout stays on main" main "$(git -C "$work" branch --show-current)"

# Existing local branch behind origin.
fresh
push_branch ABC-5/review-me
git -C "$work" fetch -q origin
git -C "$work" branch -q --no-track ABC-5/review-me origin/ABC-5/review-me
push_branch ABC-5/review-me
run p ABC-5 --branch ABC-5/review-me
check "existing behind: exit 0" 0 "$code"
check "existing behind: fast-forwarded to the remote tip" \
  "$(remote_tip ABC-5/review-me)" "$(git -C "$work" rev-parse ABC-5/review-me)"

# Existing local branch diverged from origin.
fresh
push_branch ABC-5/review-me
git -C "$work" fetch -q origin
git -C "$work" switch -q -c ABC-5/review-me origin/ABC-5/review-me
git -C "$work" commit -q --allow-empty -m local
git -C "$work" switch -q main
push_branch ABC-5/review-me
before=$(git -C "$work" rev-parse ABC-5/review-me)
run p ABC-5 --branch ABC-5/review-me
check "existing diverged: exit 1" 1 "$code"
check "existing diverged: message" "work-start: cannot update ABC-5/review-me: local \
ABC-5/review-me and origin/ABC-5/review-me diverged, reconcile them and re-run" "$err"
check "existing diverged: branch not moved" "$before" "$(git -C "$work" rev-parse ABC-5/review-me)"
check "existing diverged: no herdr call" "" "$(cat "$MOCK_LOG")"

# Existing branch only in the local repo: no fetch.
fresh
git -C "$work" branch -q ABC-5/local-only
run p ABC-5 --branch ABC-5/local-only
check "existing local only: exit 0" 0 "$code"
check "existing local only: branch not moved" \
  "$(git -C "$work" rev-parse main)" "$(git -C "$work" rev-parse ABC-5/local-only)"

# Existing branch not found.
fresh
run p ABC-5 --branch ABC-5/nope
check "existing not found: exit 1" 1 "$code"
check "existing not found: message" \
  "work-start: branch not found in the local repo or on origin: ABC-5/nope" "$err"
check "existing not found: no herdr call" "" "$(cat "$MOCK_LOG")"

# Existing branch open in a herdr workspace already.
fresh
push_branch ABC-5/review-me
MOCK_WT_LIST='{"result":{"worktrees":[{"branch":"ABC-5/review-me","path":"/wt/old",
"is_prunable":false,"open_workspace_id":"wX"}]}}' run p ABC-5 --branch ABC-5/review-me
check "existing open: exit 1" 1 "$code"
check "existing open: message names the workspace" \
  "work-start: ABC-5/review-me is open in herdr workspace wX already" "$err"
check "existing open: no agent start" "" "$(grep '^herdr agent start' "$MOCK_LOG")"

# Existing branch with a worktree and no open workspace.
fresh
push_branch ABC-5/review-me
MOCK_WT_LIST='{"result":{"worktrees":[{"branch":"ABC-5/review-me","path":"/wt/old",
"is_prunable":false}]}}' run p ABC-5 --branch ABC-5/review-me
check "existing closed: exit 0" 0 "$code"
check "existing closed: worktree opened" "herdr worktree open --cwd $work --path /wt/old --no-focus" \
  "$(grep '^herdr worktree open' "$MOCK_LOG")"
check "existing closed: agent started in the root pane" \
  "herdr agent start abc-5-review-me --kind claude --pane wO:p1" \
  "$(grep '^herdr agent start' "$MOCK_LOG")"
check "existing closed: output has the worktree" "/wt/old wO" \
  "$(jq -r '"\(.worktree) \(.workspace_id)"' <<<"$out")"

# Existing branch from a linked worktree: a new workspace, the linked worktree stays.
fresh
push_branch ABC-5/review-me
git -C "$work" worktree add -q "$d/linked" -b ABC-1/old
cwd="$d/linked" run p ABC-5 --branch ABC-5/review-me -- --effort low
check "existing from linked: exit 0" 0 "$code"
check "existing from linked: mode" existing "$(jq -r .mode <<<"$out")"
check "existing from linked: worktree opened from the main checkout" \
  "herdr worktree create --cwd $work --branch ABC-5/review-me --no-focus" \
  "$(grep '^herdr worktree create' "$MOCK_LOG")"
check "existing from linked: claude flags passed" \
  "herdr agent start abc-5-review-me --kind claude --pane wT:p1 -- --effort low" \
  "$(grep '^herdr agent start' "$MOCK_LOG")"
check "existing from linked: linked worktree stays on its branch" ABC-1/old \
  "$(git -C "$d/linked" branch --show-current)"

# Existing branch with slug text or --base.
fresh
push_branch ABC-5/review-me
run p ABC-5 'Review' --branch ABC-5/review-me
check "existing with slug text: exit 1" 1 "$code"
run p ABC-5 --branch ABC-5/review-me --base origin/main
check "existing with --base: exit 1" 1 "$code"
check "existing bad options: no herdr call" "" "$(cat "$MOCK_LOG")"

exit $fail
