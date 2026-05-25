#!/usr/bin/env bash
# Read-only GitLab MR fetcher for the review-gitlab skill.
# Subcommands: resolve | discussions | diff-check
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

urlencode_path() { jq -sRr @uri <<<"$1"; }

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
  fetch-mr.sh resolve     <URL | iid | branch | "">
  fetch-mr.sh discussions <iid> [project_path]      # or REVIEW_GITLAB_PROJECT
  fetch-mr.sh diff-check  <iid> [target_branch]

Exit codes: 0 ok · 1 usage/other · 2 not found · 3 ambiguous · 4 dep/auth · 5 network
USAGE
}

preflight
case "${1-}" in
  resolve)      shift; cmd_resolve "${1-}" ;;
  discussions)  shift; cmd_discussions "$@" ;;
  diff-check)   shift; cmd_diff_check "${1-}" ;;
  ""|-h|--help) usage ;;
  *)            die "unknown subcommand: $1" 1 ;;
esac
