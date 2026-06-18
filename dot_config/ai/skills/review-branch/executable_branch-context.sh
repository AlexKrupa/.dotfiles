#!/usr/bin/env bash
# Usage: branch-context.sh [parent-override]
# Resolves branch-vs-parent review context deterministically and prints it as a
# keyed text block on stdout. Fail-fast: cheap local guards abort before any diff.
#
# With no arg, parent is auto-detected (upstream -> main/master/develop).
# With an arg, that ref is used as parent (validated to exist locally).
#
# Aborts (exit 1, message on stderr) when: not a repo; branch == parent;
# parent unresolved; override ref missing.
#
# Does NOT emit the full diff (unbounded). It prints the exact `git diff` command
# to run for the reviewable content, plus bounded metadata (--stat, log, status).
set -euo pipefail

override="${1:-}"

die() { printf '%s\n' "$1" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "Not inside a git work tree — nothing to review."

branch="$(git rev-parse --abbrev-ref HEAD)"

if [ -n "$override" ]; then
  git rev-parse --verify --quiet "$override" >/dev/null \
    || die "Override parent ref '$override' not found locally."
  parent="$override"
  parent_source="override"
else
  if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    parent="$upstream"
    parent_source="upstream"
  else
    parent=""
    for cand in main master develop; do
      if git show-ref --verify --quiet "refs/heads/$cand"; then
        parent="$cand"
        parent_source="default-branch"
        break
      fi
    done
    [ -n "$parent" ] || die "Could not resolve parent branch (no upstream, no main/master/develop)."
  fi
fi

# Compare resolved SHAs, not names: branch may equal parent via a differently
# named upstream that points at the same commit.
if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$parent")" ]; then
  die "Branch '$branch' has no diff vs parent '$parent' — nothing to review."
fi

status="$(git status --porcelain)"
diffstat="$(git diff "$parent...HEAD" --stat)"
log="$(git log "$parent..HEAD" --oneline)"
shortlog="$(git shortlog -sn "$parent..HEAD")"

emit_block() {
  local label="$1" body="$2"
  printf '## %s\n' "$label"
  if [ -n "$body" ]; then printf '%s\n' "$body"; else printf '(none)\n'; fi
  printf '\n'
}

printf 'branch: %s\n' "$branch"
printf 'parent: %s\n' "$parent"
printf 'parent-source: %s\n' "$parent_source"
printf 'uncommitted: %s\n\n' "$([ -n "$status" ] && echo yes || echo no)"

printf 'diff-command: git diff %s...HEAD\n\n' "$parent"

emit_block "Diffstat" "$diffstat"
emit_block "Commits" "$log"
emit_block "Authors (shortlog)" "$shortlog"
emit_block "Uncommitted (not in audit scope)" "$status"
