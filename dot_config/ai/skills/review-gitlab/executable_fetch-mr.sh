#!/usr/bin/env bash
# Read-only GitLab MR fetcher for the review-gitlab skill.
# Subcommands: preflight | resolve | locate | fetch | discussions | diff-check
# Exit codes: 0 ok, 1 usage/other, 2 not found, 3 ambiguous, 4 missing dep / auth, 5 network

set -euo pipefail

E_NOTFOUND=2
E_AMBIGUOUS=3
E_DEP=4
E_NETWORK=5

die() { echo "$1" >&2; exit "${2:-1}"; }

preflight() {
  command -v glab >/dev/null || die "glab not installed" "$E_DEP"
  command -v jq   >/dev/null || die "jq not installed"   "$E_DEP"
}

urlencode_path() { jq -nRr --arg s "$1" '$s|@uri'; }

# preflight: deterministic prereqs in fail-fast order (cheap local -> network).
# glab/jq presence already verified by top-level preflight().
cmd_preflight() {
  [[ "${HERDR_ENV-}" == 1 ]] \
    || die "not in a Herdr pane, the review needs a Herdr worktree workspace" "$E_DEP"
  glab auth status >/dev/null 2>&1 \
    || die "glab not authenticated, run: glab auth login" "$E_DEP"
  echo "ok"
}

# pick_remote [project_path]: one remote -> use it. Several -> the one whose URL
# contains project_path, else origin, else the first listed.
pick_remote() {
  local project="${1-}" remotes count r url
  remotes=$(git remote)
  [[ -n "$remotes" ]] || die "no git remotes configured" 1
  count=$(grep -c . <<<"$remotes")
  if [[ "$count" -eq 1 ]]; then echo "$remotes"; return; fi
  if [[ -n "$project" ]]; then
    while IFS= read -r r; do
      url=$(git remote get-url "$r" 2>/dev/null || echo "")
      [[ "$url" == *"$project"* ]] && { echo "$r"; return; }
    done <<<"$remotes"
  fi
  git remote get-url origin >/dev/null 2>&1 && { echo origin; return; }
  head -n1 <<<"$remotes"
}

# remote_matches <url> <project_path>: true when the URL points at the project
# (ssh or https, with or without .git), not at a project whose path only starts with it.
remote_matches() {
  local url="${1%.git}" project="$2"
  [[ "$url" == *":$project" || "$url" == *"/$project" ]]
}

repo_matches() {
  local repo="$1" project="$2" r
  for r in $(git -C "$repo" remote); do
    remote_matches "$(git -C "$repo" remote get-url "$r")" "$project" && return 0
  done
  return 1
}

# locate <project_path>: prints the local clone of the project. The current repo
# wins when it matches. Otherwise scans main checkouts under ~/src.
cmd_locate() {
  local project="${1-}"
  [[ -n "$project" ]] || die "usage: locate <project_path>" 1

  local current
  current=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [[ -n "$current" ]] && repo_matches "$current" "$project"; then
    echo "$current"
    return
  fi

  # Linked worktrees and submodules have a .git file, not a directory.
  local git_dir repo matches=()
  while IFS= read -r git_dir; do
    repo=$(dirname "$git_dir")
    repo_matches "$repo" "$project" && matches+=("$repo")
  done < <(find "$HOME/src" -maxdepth 5 -type d -name .git -prune 2>/dev/null)

  case "${#matches[@]}" in
    0) die "no clone of $project under ~/src" "$E_NOTFOUND" ;;
    1) echo "${matches[0]}" ;;
    *)
      {
        echo "multiple clones of $project under ~/src:"
        printf '  %s\n' "${matches[@]}"
      } >&2
      exit "$E_AMBIGUOUS"
      ;;
  esac
}

# worktree_of <branch>: prints the path of the worktree that has the branch checked out.
worktree_of() {
  git worktree list --porcelain | awk -v ref="refs/heads/$1" '
    /^worktree / { path = substr($0, 10) }
    $0 == "branch " ref { print path; exit }'
}

# fetch <source_branch> <target_branch> [project_path]
# Brings the local <source> branch to the MR tip without a checkout in the current
# worktree, and refreshes the target's remote-tracking ref (does NOT touch the user's
# local target branch). review-branch then diffs against a fresh base.
# Emits JSON: remote, source_branch, target_branch, target_ref.
cmd_fetch() {
  local source="${1-}" target="${2-}" project="${3-}"
  [[ -n "$source" && -n "$target" ]] \
    || die "usage: fetch <source_branch> <target_branch> [project_path]" 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not in a git repo" 1

  local remote
  remote=$(pick_remote "$project")
  git fetch "$remote" "$source" "$target" >/dev/null 2>&1 \
    || die "git fetch $remote $source $target failed" "$E_NETWORK"

  local tip="$remote/$source" checkout
  if ! git show-ref --verify --quiet "refs/heads/$source"; then
    git branch --quiet --track "$source" "$tip"
  elif [[ "$(git rev-parse "$source")" == "$(git rev-parse "$tip")" ]]; then
    :
  elif git merge-base --is-ancestor "$source" "$tip"; then
    checkout=$(worktree_of "$source")
    if [[ -n "$checkout" ]]; then
      git -C "$checkout" merge --ff-only --quiet "$tip" \
        || die "could not fast-forward $source in $checkout to $tip" 1
    else
      git branch --quiet --force "$source" "$tip"
    fi
  elif git merge-base --is-ancestor "$tip" "$source"; then
    # Local commits not pushed yet. Keep them, diff-check reports the drift.
    :
  else
    die "local $source and $tip diverged, reconcile them and re-run" 1
  fi

  jq -n \
    --arg remote "$remote" --arg source "$source" --arg target "$target" \
    --arg target_ref "$remote/$target" \
    '{remote:$remote, source_branch:$source, target_branch:$target, target_ref:$target_ref}'
}

# Pull the MR fields out of `glab mr view --output json`.
project_mr_view() {
  jq '{
    iid,
    project_path: (.web_url | capture("https?://[^/]+/(?<p>.+)/-/merge_requests/").p),
    source_branch,
    target_branch,
    web_url,
    state,
    draft,
    labels,
    author: .author.username,
    pipeline_status: (.head_pipeline.status // "n/a"),
    description: (.description // "")
  }'
}

glab_mr_view_json() {
  local iid="$1" repo="${2-}"
  if [[ -n "$repo" ]]; then
    glab mr view "$iid" -R "$repo" --output json 2>/dev/null \
      || die "glab mr view failed (iid=$iid repo=$repo)" "$E_NETWORK"
  else
    glab mr view "$iid" --output json 2>/dev/null \
      || die "glab mr view failed (iid=$iid)" "$E_NETWORK"
  fi
}

resolve_branch_to_iid() {
  local branch="$1" json count
  json=$(glab mr list --source-branch "$branch" --output json 2>/dev/null) \
    || die "glab mr list failed for branch '$branch'" "$E_NETWORK"
  count=$(jq 'length' <<<"$json")
  case "$count" in
    0) die "no open MR for branch '$branch'" "$E_NOTFOUND" ;;
    1) jq -r '.[0].iid' <<<"$json" ;;
    *)
      {
        echo "multiple open MRs for branch '$branch':"
        jq -r '.[] | "  iid \(.iid): \(.title) (\(.web_url))"' <<<"$json"
      } >&2
      exit "$E_AMBIGUOUS"
      ;;
  esac
}

cmd_resolve() {
  local input="${1-}"
  if [[ -z "$input" ]]; then
    input=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) \
      || die "not in a git repo" 1
    [[ "$input" != "HEAD" ]] || die "detached HEAD; check out a branch first" 1
  fi

  local mr_json
  if [[ "$input" =~ ^https?:// ]]; then
    if [[ "$input" =~ ^https?://[^/]+/(.+)/-/merge_requests/([0-9]+) ]]; then
      mr_json=$(glab_mr_view_json "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}")
    else
      die "could not parse MR URL: $input" 1
    fi
  elif [[ "$input" =~ ^[0-9]+$ ]]; then
    mr_json=$(glab_mr_view_json "$input")
  else
    local iid
    iid=$(resolve_branch_to_iid "$input")
    mr_json=$(glab_mr_view_json "$iid")
  fi

  project_mr_view <<<"$mr_json"
}

# discussions <iid> [project_path]
# project_path can also come from $REVIEW_GITLAB_PROJECT. When neither is set,
# the script asks `glab mr view` to discover it (one extra round-trip).
cmd_discussions() {
  local iid="${1-}"
  [[ -n "$iid" ]] || die "usage: discussions <iid> [project_path]" 1
  local project="${2-${REVIEW_GITLAB_PROJECT-}}"
  if [[ -z "$project" ]]; then
    project=$(glab_mr_view_json "$iid" \
      | jq -r '.web_url | capture("https?://[^/]+/(?<p>.+)/-/merge_requests/").p')
    [[ -n "$project" && "$project" != "null" ]] \
      || die "could not derive project_path for iid $iid" "$E_NETWORK"
  fi

  local enc; enc=$(urlencode_path "$project")
  glab api "projects/$enc/merge_requests/$iid/discussions" 2>/dev/null \
    | jq '[
        .[]
        # Drop discussions whose every note is a GitLab system note
        # (label changes, assignee churn, pipeline status pings).
        | select(any(.notes[]; .system == false))
        | {
            id,
            individual_note,
            resolvable: (any(.notes[]; .resolvable == true)),
            resolved:   (all(.notes[]; (.resolvable != true) or (.resolved == true))),
            note_count: (.notes | length),
            authors:    ([.notes[] | select(.system != true) | .author.username] | unique),
            first_body: ((.notes | map(select(.system != true)) | .[0].body // "") | .[0:280]),
            files:      ([.notes[].position.new_path? // empty] | unique)
          }
      ]' \
    || die "glab api discussions failed" "$E_NETWORK"
}

# diff-check <iid>: compare the set of changed files (and total +/- counts)
# between the local branch and the MR. A full-diff hash compare is too brittle
# (whitespace/headers). File-set + line-count is a stable check.
cmd_diff_check() {
  local iid="${1-}" target="${2-}"
  [[ -n "$iid" ]] || die "usage: diff-check <iid> [target_branch]" 1

  if [[ -z "$target" ]]; then
    target=$(glab_mr_view_json "$iid" | jq -r '.target_branch')
    [[ -n "$target" && "$target" != "null" ]] || die "could not read target_branch" 1
  fi

  local local_files mr_files
  local_files=$(git diff "${target}...HEAD" --name-only | sort -u)
  mr_files=$(glab mr diff "$iid" 2>/dev/null \
    | awk '/^diff --git / { sub(/^a\//, "", $3); print $3 }' \
    | sort -u) \
    || die "glab mr diff failed" "$E_NETWORK"

  if [[ "$local_files" == "$mr_files" ]]; then
    exit 0
  fi
  {
    echo "local diff differs from MR diff (file sets)"
    diff <(echo "$local_files") <(echo "$mr_files") || true
  } >&2
  exit 1
}

usage() {
  cat <<'USAGE'
fetch-mr.sh - read-only GitLab MR fetcher for the review-gitlab skill.

Usage:
  fetch-mr.sh preflight
  fetch-mr.sh resolve     <URL | iid | branch | "">
  fetch-mr.sh locate      <project_path>
  fetch-mr.sh fetch       <source_branch> <target_branch> [project_path]
  fetch-mr.sh discussions <iid> [project_path]      # or REVIEW_GITLAB_PROJECT
  fetch-mr.sh diff-check  <iid> [target_branch]

Exit codes: 0 ok · 1 usage/other · 2 not found · 3 ambiguous · 4 dep/auth · 5 network
USAGE
}

preflight
case "${1-}" in
  preflight)    cmd_preflight ;;
  resolve)      shift; cmd_resolve "${1-}" ;;
  locate)       shift; cmd_locate "$@" ;;
  fetch)        shift; cmd_fetch "$@" ;;
  discussions)  shift; cmd_discussions "$@" ;;
  diff-check)   shift; cmd_diff_check "$@" ;;
  ""|-h|--help) usage ;;
  *)            die "unknown subcommand: $1" 1 ;;
esac
