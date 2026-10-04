#!/usr/bin/env bash
# Usage: git-diff-context.sh [parent-override]
#        git-diff-context.sh --uncommitted | --staged
#        git-diff-context.sh --uncommitted | --staged --with-branch [parent-override]
#        git-diff-context.sh --rev <rev | A..B | A...B>
# Prints the review context of a diff as a keyed text block on stdout.
# Cheap local guards abort before any diff.
#
# Scopes: default - branch commits vs parent. --uncommitted - the working tree and
# untracked files vs HEAD. --staged - the index vs HEAD. --with-branch adds the branch
# commits vs parent to --uncommitted or --staged. --rev - one commit vs its first
# parent, or a range (A..B and A...B both mean the commits in B and not in A),
# independent of the current branch.
#
# The --uncommitted and --staged scopes use HEAD as the parent. In the other scopes,
# with no arg, the parent is the nearest local branch that is a strict ancestor of
# HEAD. When that branch is mainline (main/master/develop or the remote default
# branch), the remote copy is fetched (best-effort) and the remote-tracking ref is
# the base. A stale local mainline would otherwise pollute the diff. Intermediate
# stack parents stay anchored on their local tip. With an arg, that ref is the
# parent (validated to exist).
#
# Aborts (exit 1, message on stderr) when: not a repo, no diff in scope, parent
# unresolved, override ref missing.
#
# Does NOT emit the full diff (unbounded). It prints the `git diff` command to run
# for the reviewable content, plus bounded metadata (--stat, log, status).
set -euo pipefail

die() { printf '%s\n' "$1" >&2; exit 1; }

scope=branch
rev=""
case "${1:-}" in
  --uncommitted) scope=uncommitted; shift ;;
  --staged) scope=staged; shift ;;
  --with-branch) die "--with-branch needs --uncommitted or --staged." ;;
  --rev)
    scope=rev
    rev="${2:?--rev needs a commit or a range}"
    shift 2
    [ $# -eq 0 ] || die "--rev takes no parent override."
    ;;
esac
if [ "${1:-}" = --with-branch ]; then
  scope="branch-$scope"
  shift
fi
override="${1:-}"
if [ -n "$override" ] && { [ "$scope" = uncommitted ] || [ "$scope" = staged ]; }; then
  die "A parent override needs --with-branch."
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "Not inside a git work tree — nothing to review."

branch="$(git rev-parse --abbrev-ref HEAD)"
tip="$branch"
parent_fetched=no

verify_ref() {
  git rev-parse --verify --quiet "$1^{commit}" >/dev/null || die "Ref '$1' not found."
}

if [ "$scope" = rev ]; then
  if [[ "$rev" == *..* ]]; then
    parent="${rev%%..*}"
    tip="${rev#*..}"
    tip="${tip#.}"
    [ -n "$tip" ] || tip=HEAD
    verify_ref "$parent"
  else
    tip="$rev"
    parent="$rev^"
    verify_ref "$tip"
    git rev-parse --verify --quiet "$parent" >/dev/null || die "Commit '$rev' has no parent."
  fi
  verify_ref "$tip"
  parent_source="rev"
elif [ "$scope" = uncommitted ] || [ "$scope" = staged ]; then
  parent=HEAD
  parent_source="head"
elif [ -n "$override" ]; then
  git rev-parse --verify --quiet "$override" >/dev/null \
    || die "Override parent ref '$override' not found."
  parent="$override"
  parent_source="override"
else
  # Used to classify the nearest ancestor as trunk vs stack parent.
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

  # The nearest strict-ancestor local branch is the immediate stack parent.
  nearest=""
  nearest_count=""
  while IFS= read -r cand; do
    [ "$cand" = "$branch" ] && continue
    git merge-base --is-ancestor "$cand" HEAD 2>/dev/null || continue  # guard non-zero under set -e
    count="$(git rev-list --count "$cand..HEAD")"
    [ "$count" -gt 0 ] || continue  # same commit - the SHA guard below covers it
    if [ -z "$nearest_count" ] || [ "$count" -lt "$nearest_count" ]; then
      nearest="$cand"
      nearest_count="$count"
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

  if [ -n "$nearest" ] && ! is_mainline "$nearest"; then
    # Intermediate stack parent: the split point is your local tip. No fetch.
    parent="$nearest"
    parent_source="ancestor-branch"
  else
    mainline=""
    if [ -n "$nearest" ]; then
      mainline="$nearest"
    elif [ "${#mainlines[@]}" -gt 0 ]; then
      mainline="${mainlines[0]}"
    fi
    [ -n "$mainline" ] \
      || die "Could not resolve parent branch (no ancestor branch, no main/master/develop)."

    # A fresh remote-tracking ref keeps other people's commits out of the diff.
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

status="$(git status --porcelain)"
log_range="$parent..HEAD"
report_prefix="$scope"
case "$scope" in
  branch)
    # Compare resolved SHAs, not names: branch may equal parent via a differently
    # named upstream that points at the same commit.
    if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$parent")" ]; then
      die "Branch '$branch' has no diff vs parent '$parent' — nothing to review."
    fi
    diff_args=("$parent...HEAD")
    report_prefix=""
    ;;
  uncommitted)
    log_range="HEAD..HEAD"
    diff_args=(HEAD)
    if git diff --quiet HEAD && [ -z "$(git ls-files --others --exclude-standard)" ]; then
      die "No uncommitted changes — nothing to review."
    fi
    ;;
  staged)
    log_range="HEAD..HEAD"
    diff_args=(--cached)
    git diff --quiet --cached && die "No staged changes — nothing to review."
    ;;
  branch-uncommitted)
    diff_args=(--merge-base "$parent")
    # `git diff` does not show untracked files, so check them separately.
    if git diff --quiet "${diff_args[@]}" && [ -z "$(git ls-files --others --exclude-standard)" ]; then
      die "No committed or uncommitted changes vs parent '$parent' — nothing to review."
    fi
    ;;
  branch-staged)
    diff_args=(--cached --merge-base "$parent")
    git diff --quiet "${diff_args[@]}" \
      && die "No committed or staged changes vs parent '$parent' — nothing to review."
    ;;
  rev)
    log_range="$parent..$tip"
    report_prefix="$rev"
    diff_args=("$parent...$tip")
    git diff --quiet "${diff_args[@]}" && die "No diff in '$rev' — nothing to review."
    ;;
esac

diffstat="$(git diff --stat "${diff_args[@]}")"
log="$(git log "$log_range" --oneline)"
shortlog="$(git shortlog -sn "$log_range")"

emit_block() {
  local label="$1" body="$2"
  printf '## %s\n' "$label"
  if [ -n "$body" ]; then printf '%s\n' "$body"; else printf '(none)\n'; fi
  printf '\n'
}

printf 'scope: %s\n' "$scope"
printf 'branch: %s\n' "$branch"
printf 'tip: %s\n' "$tip"
printf 'parent: %s\n' "$parent"
printf 'parent-source: %s\n' "$parent_source"
printf 'parent-fetched: %s\n' "$parent_fetched"
printf 'uncommitted: %s\n\n' "$([ -n "$status" ] && echo yes || echo no)"

printf 'log-range: %s\n' "$log_range"
printf 'report-prefix: %s\n' "$report_prefix"
printf 'diff-command: git diff %s\n\n' "${diff_args[*]}"

emit_block "Diffstat" "$diffstat"
emit_block "Commits" "$log"
emit_block "Authors (shortlog)" "$shortlog"
emit_block "Uncommitted" "$status"
