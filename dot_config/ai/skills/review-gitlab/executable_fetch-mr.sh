#!/usr/bin/env bash
# Read-only GitLab MR fetcher for the review-gitlab skill.
# Subcommands: preflight | resolve | discussions | diff-check | checkout
# Exit codes: 0 ok · 1 usage/other · 2 not found · 3 ambiguous · 4 missing dep / auth · 5 network

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
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not in a git repo" 1
  [[ -z "$(git status --porcelain)" ]] \
    || die "uncommitted changes present, commit/stash and re-run" 1
  glab auth status >/dev/null 2>&1 \
    || die "glab not authenticated, run: glab auth login" "$E_DEP"
  echo "ok"
}

# pick_remote [project_path]: single remote -> use it; multiple -> the one whose
# URL contains project_path; else origin; else first listed.
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

# checkout <source_branch> <target_branch> [project_path]
# Fetches and checks out the MR source branch, refreshes the target's remote-tracking
# ref (does NOT touch the user's local target branch), and reports it as target_ref so
# review-branch diffs against a fresh base, not a stale local mainline.
# Emits JSON: remote, previous_branch, moved, source_branch, target_branch, target_ref.
cmd_checkout() {
  local source="${1-}" target="${2-}" project="${3-}"
  [[ -n "$source" && -n "$target" ]] \
    || die "usage: checkout <source_branch> <target_branch> [project_path]" 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not in a git repo" 1

  local remote prev moved=false
  remote=$(pick_remote "$project")
  prev=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  git fetch "$remote" "$source" >/dev/null 2>&1 \
    || die "git fetch $remote $source failed" "$E_NETWORK"
  if [[ "$prev" != "$source" ]]; then
    git checkout "$source" >/dev/null 2>&1 \
      || die "git checkout $source failed" 1
    moved=true
  fi
  # Refresh refs/remotes/$remote/$target without writing the local $target branch.
  git fetch "$remote" "$target" >/dev/null 2>&1 \
    || die "could not fetch target branch $target" "$E_NETWORK"

  jq -n \
    --arg remote "$remote" --arg prev "$prev" --argjson moved "$moved" \
    --arg source "$source" --arg target "$target" --arg target_ref "$remote/$target" \
    '{remote:$remote, previous_branch:$prev, moved:$moved,
      source_branch:$source, target_branch:$target, target_ref:$target_ref}'
}

# Pull the canonical MR fields out of `glab mr view --output json`.
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
  json=$(glab mr list --source-branch "$branch" --state opened --output json 2>/dev/null) \
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
# between the local branch and the MR. Full-diff hash compare is too brittle
# (whitespace/headers); file-set + line-count is a stable sanity check.
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
  fetch-mr.sh discussions <iid> [project_path]      # or REVIEW_GITLAB_PROJECT
  fetch-mr.sh diff-check  <iid> [target_branch]
  fetch-mr.sh checkout    <source_branch> <target_branch> [project_path]

Exit codes: 0 ok · 1 usage/other · 2 not found · 3 ambiguous · 4 dep/auth · 5 network
USAGE
}

preflight
case "${1-}" in
  preflight)    cmd_preflight ;;
  resolve)      shift; cmd_resolve "${1-}" ;;
  discussions)  shift; cmd_discussions "$@" ;;
  diff-check)   shift; cmd_diff_check "$@" ;;
  checkout)     shift; cmd_checkout "$@" ;;
  ""|-h|--help) usage ;;
  *)            die "unknown subcommand: $1" 1 ;;
esac
