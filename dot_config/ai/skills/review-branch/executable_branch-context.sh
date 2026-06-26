#!/usr/bin/env bash
# Usage: branch-context.sh [parent-override]
# Resolves branch-vs-parent review context deterministically and prints it as a
# keyed text block on stdout. Fail-fast: cheap local guards abort before any diff.
#
# With no arg, parent is auto-detected by git topology: the nearest local branch
# that is a strict ancestor of HEAD is the immediate stack parent. When that
# resolves to mainline (main/master/develop or the remote default branch), the
# remote copy is fetched (best-effort) and the remote-tracking ref is used as the
# base, so a stale local mainline does not pollute the diff. Intermediate stack
# parents stay anchored on their local tip (their split point is your local tip).
# With an arg, that ref is used as parent (validated to exist).
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
parent_fetched=no

if [ -n "$override" ]; then
  git rev-parse --verify --quiet "$override" >/dev/null \
    || die "Override parent ref '$override' not found."
  parent="$override"
  parent_source="override"
else
  # Mainline set: local main/master/develop plus each remote's default branch
  # (its HEAD symref). Used to classify the nearest ancestor as trunk vs stack parent.
  mainlines=()
  for cand in main master develop; do
    if git show-ref --verify --quiet "refs/heads/$cand"; then
      mainlines+=("$cand")
    fi
  done
  for remote in $(git remote); do
    if rdefault="$(git symbolic-ref --quiet "refs/remotes/$remote/HEAD" 2>/dev/null)"; then
      mainlines+=("${rdefault##*/}")
    fi
  done

  is_mainline() {
    local name="$1" m
    for m in "${mainlines[@]:-}"; do
      [ "$name" = "$m" ] && return 0
    done
    return 1
  }

  # Nearest strict-ancestor local branch = smallest positive commit distance to HEAD.
  # That is the immediate stack parent; mainline wins when no intermediate branch exists.
  nearest=""
  nearest_count=""
  while IFS= read -r cand; do
    [ "$cand" = "$branch" ] && continue
    git merge-base --is-ancestor "$cand" HEAD 2>/dev/null || continue  # guard non-zero under set -e
    count="$(git rev-list --count "$cand..HEAD")"
    [ "$count" -gt 0 ] || continue  # same commit; SHA-equality guard below covers it
    if [ -z "$nearest_count" ] || [ "$count" -lt "$nearest_count" ]; then
      nearest="$cand"
      nearest_count="$count"
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

  if [ -n "$nearest" ] && ! is_mainline "$nearest"; then
    # Intermediate stack parent: split point is your local tip, so anchor local, no fetch.
    parent="$nearest"
    parent_source="ancestor-branch"
  else
    # Mainline base. Prefer the nearest-ancestor mainline name, else first existing mainline.
    mainline=""
    if [ -n "$nearest" ]; then
      mainline="$nearest"
    elif [ "${#mainlines[@]}" -gt 0 ]; then
      mainline="${mainlines[0]}"
    fi
    [ -n "$mainline" ] \
      || die "Could not resolve parent branch (no ancestor branch, no main/master/develop)."

    # Anchor on a FRESH remote-tracking ref so a stale local mainline does not leak
    # other people's commits into the diff. Best-effort: fall back to local on failure.
    remote="$(git config "branch.$mainline.remote" 2>/dev/null || true)"
    [ -n "$remote" ] || remote="$(git remote | head -1)"
    parent_source="default-branch"
    if [ -n "$remote" ] && git fetch "$remote" "$mainline" >/dev/null 2>&1; then
      parent="$remote/$mainline"
      parent_fetched=yes
    else
      parent="$mainline"
      parent_fetched=no
      if [ -n "$remote" ]; then
        printf 'warning: could not fetch %s/%s (offline?); using possibly-stale local %s\n' \
          "$remote" "$mainline" "$mainline" >&2
      else
        printf 'warning: no remote for %s; using local %s (may be stale)\n' \
          "$mainline" "$mainline" >&2
      fi
    fi
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
printf 'parent-fetched: %s\n' "$parent_fetched"
printf 'uncommitted: %s\n\n' "$([ -n "$status" ] && echo yes || echo no)"

printf 'diff-command: git diff %s...HEAD\n\n' "$parent"

emit_block "Diffstat" "$diffstat"
emit_block "Commits" "$log"
emit_block "Authors (shortlog)" "$shortlog"
emit_block "Uncommitted (not in audit scope)" "$status"
