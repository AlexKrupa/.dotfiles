#!/usr/bin/env bash
# Checks open-findings.sh with a scratch git repo and fake Superpowers workspaces.
set -u

script="$(cd "$(dirname "$0")" && pwd)/open-findings.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

repo="$tmp/repo"
sdd="$repo/.superpowers/sdd"
mkdir -p "$repo/docs" "$tmp/ai" "$sdd/foo" "$sdd/bar"
git -C "$repo" init -q
inside="$repo/docs/foo.md"
outside="$tmp/ai/bar.md"
echo '# Foo' >"$inside"
echo '# Bar' >"$outside"
echo 'docs/foo.md' >"$sdd/foo/plan-path"
echo "$outside" >"$sdd/bar/plan-path"
cd "$repo" || exit 1

out=$("$script" "$inside"); code=$?
check "no ledger: exit 0" 0 "$code"
check "no ledger: workspace path only" "$sdd/foo" "$out"

cat >"$sdd/foo/progress.md" <<'EOF'
# SDD ledger — plan: docs/foo.md
Task 1: complete (commits a..b, tests: make test → pass)
Task 1: minor (deferred): name is long
EOF
out=$("$script" "$inside")
check "plan in repo: workspace and file paths" "$sdd/foo
$sdd/foo/open-findings.md" "$out"
check "plan in repo: deferred line only" "Task 1: minor (deferred): name is long" \
  "$(cat "$sdd/foo/open-findings.md")"

cat >"$sdd/bar/progress.md" <<'EOF'
# SDD ledger — plan: /x/bar.md
Ruling: keep the cache — spec is silent — a stale read
Task 2: complete (commits c..d, tests: make test → pass)
Task 2: parked — retry loop — Ruling: the spec caps retries — a slow failure
EOF
out=$("$script" "$outside")
check "plan outside repo: workspace and file paths" "$sdd/bar
$sdd/bar/open-findings.md" "$out"
check "plan outside repo: ruling lines" "Ruling: keep the cache — spec is silent — a stale read
Task 2: parked — retry loop — Ruling: the spec caps retries — a slow failure" \
  "$(cat "$sdd/bar/open-findings.md")"

echo 'Task 1: complete (commits a..b, tests: make test → pass)' >"$sdd/foo/progress.md"
out=$("$script" "$inside")
check "no open lines: workspace path only, no file" "$sdd/foo no" \
  "$out $([ -e "$sdd/foo/open-findings.md" ] && echo yes || echo no)"

rm -rf "$sdd/bar"
out=$("$script" "$outside")
check "no workspace: no output" "" "$out"

"$script" "$tmp/missing.md" 2>/dev/null; code=$?
check "missing plan: exit 1" 1 "$code"

exit $fail
