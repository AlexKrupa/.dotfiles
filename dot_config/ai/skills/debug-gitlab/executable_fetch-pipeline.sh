#!/usr/bin/env bash
# Read-only GitLab pipeline/job/MR fetcher for the debug-gitlab skill.
# Subcommands: resolve | failed-jobs | test-failures | trace
# Exit codes: 0 ok · 1 usage/other · 2 not found · 3 ambiguous · 4 dep/auth · 5 network

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

# Derive the GitLab project_path (group/proj) for the current repo. Order:
# 1) $DEBUG_GITLAB_PROJECT, 2) `glab repo view`, 3) git remote URL.
derive_project() {
  if [[ -n "${DEBUG_GITLAB_PROJECT-}" ]]; then
    echo "$DEBUG_GITLAB_PROJECT"
    return
  fi
  local p=""
  p=$(glab repo view --output json 2>/dev/null \
    | jq -r '.fullPath // .path_with_namespace // empty' 2>/dev/null) || p=""
  if [[ -z "$p" || "$p" == "null" ]]; then
    p=$(git config --get remote.origin.url 2>/dev/null \
      | sed -E 's|^(https?://[^/]+/|git@[^:]+:)||; s|\.git$||')
  fi
  [[ -n "$p" ]] || die "could not derive project_path (set DEBUG_GITLAB_PROJECT or pass as arg)" 1
  echo "$p"
}

glab_pipeline_view() {
  local pid="$1" project="${2-}"
  if [[ -n "$project" ]]; then
    glab ci get --pipeline-id "$pid" -R "$project" --output json 2>/dev/null \
      || die "glab ci get failed (pid=$pid repo=$project)" "$E_NETWORK"
  else
    glab ci get --pipeline-id "$pid" --output json 2>/dev/null \
      || die "glab ci get failed (pid=$pid)" "$E_NETWORK"
  fi
}

# Returns the iid (number) or empty. >1 open MR -> exit 3.
resolve_mr_for_branch() {
  local branch="$1" project="${2-}" json count
  if [[ -n "$project" ]]; then
    json=$(glab mr list --source-branch "$branch" --state opened -R "$project" --output json 2>/dev/null) \
      || die "glab mr list failed for branch '$branch'" "$E_NETWORK"
  else
    json=$(glab mr list --source-branch "$branch" --state opened --output json 2>/dev/null) \
      || die "glab mr list failed for branch '$branch'" "$E_NETWORK"
  fi
  count=$(jq 'length' <<<"$json")
  case "$count" in
    0) echo "" ;;
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

mr_target_branch() {
  local iid="$1" project="${2-}"
  if [[ -n "$project" ]]; then
    glab mr view "$iid" -R "$project" --output json 2>/dev/null | jq -r '.target_branch // empty'
  else
    glab mr view "$iid" --output json 2>/dev/null | jq -r '.target_branch // empty'
  fi
}

emit_context() {
  local pjson="$1" project="$2"
  local ref iid target=""
  ref=$(jq -r '.ref // ""' <<<"$pjson")
  iid=$(resolve_mr_for_branch "$ref" "$project")
  if [[ -n "$iid" ]]; then
    target=$(mr_target_branch "$iid" "$project")
  fi
  jq -n \
    --arg project_path "$project" \
    --argjson p "$pjson" \
    --arg target "$target" \
    --arg iid "$iid" \
    '{
      project_path: $project_path,
      pipeline_id:  $p.id,
      sha:          ($p.sha // ""),
      status:       ($p.status // ""),
      ref:          ($p.ref // ""),
      source_branch: ($p.ref // ""),
      target_branch: (($target | select(length>0)) // null),
      web_url:      ($p.web_url // ""),
      mr_iid:       (($iid | select(length>0) | tonumber) // null)
    }'
}

cmd_resolve() {
  local input="${1-}"
  local project="" pid="" pjson=""

  if [[ -z "$input" ]]; then
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) \
      || die "not in a git repo" 1
    [[ "$branch" != "HEAD" ]] || die "detached HEAD; check out a branch first" 1
    project=$(derive_project)
    pjson=$(glab ci get --branch "$branch" -R "$project" --output json 2>/dev/null) \
      || die "no pipeline for branch '$branch'" "$E_NOTFOUND"
  elif [[ "$input" =~ ^https?://[^/]+/(.+)/-/pipelines/([0-9]+) ]]; then
    project="${BASH_REMATCH[1]}"
    pid="${BASH_REMATCH[2]}"
    pjson=$(glab_pipeline_view "$pid" "$project")
  elif [[ "$input" =~ ^https?://[^/]+/(.+)/-/jobs/([0-9]+) ]]; then
    project="${BASH_REMATCH[1]}"
    local jid="${BASH_REMATCH[2]}" enc
    enc=$(urlencode_path "$project")
    pid=$(glab api "projects/$enc/jobs/$jid" 2>/dev/null | jq -r '.pipeline.id // empty') \
      || die "glab api jobs/$jid failed" "$E_NETWORK"
    [[ -n "$pid" ]] || die "no pipeline for job $jid" "$E_NOTFOUND"
    pjson=$(glab_pipeline_view "$pid" "$project")
  elif [[ "$input" =~ ^https?://[^/]+/(.+)/-/merge_requests/([0-9]+) ]]; then
    project="${BASH_REMATCH[1]}"
    local iid="${BASH_REMATCH[2]}" mrjson enc
    mrjson=$(glab mr view "$iid" -R "$project" --output json 2>/dev/null) \
      || die "glab mr view failed (iid=$iid repo=$project)" "$E_NETWORK"
    pid=$(jq -r '.head_pipeline.id // empty' <<<"$mrjson")
    if [[ -z "$pid" ]]; then
      enc=$(urlencode_path "$project")
      pid=$(glab api "projects/$enc/merge_requests/$iid/pipelines" 2>/dev/null \
        | jq -r '.[0].id // empty')
      [[ -n "$pid" ]] || die "no pipeline for MR $iid" "$E_NOTFOUND"
    fi
    pjson=$(glab_pipeline_view "$pid" "$project")
  elif [[ "$input" =~ ^[0-9]+$ ]]; then
    die "bare numeric id is ambiguous; pass a full URL (pipelines/jobs/merge_requests)" 1
  else
    project=$(derive_project)
    pjson=$(glab ci get --branch "$input" -R "$project" --output json 2>/dev/null) \
      || die "no pipeline for branch '$input'" "$E_NOTFOUND"
  fi

  emit_context "$pjson" "$project"
}

cmd_failed_jobs() {
  local pid="${1-}" project="${2-}"
  [[ -n "$pid" ]] || die "usage: failed-jobs <pipeline_id> [project_path]" 1
  [[ -n "$project" ]] || project=$(derive_project)
  local enc; enc=$(urlencode_path "$project")
  glab api "projects/$enc/pipelines/$pid/jobs?scope=failed" 2>/dev/null \
    | jq '[ .[] | {
        id, name, stage, failure_reason, allow_failure, web_url,
        started_at, finished_at, duration: (.duration // 0)
      } ]' \
    || die "glab api failed-jobs failed (pid=$pid)" "$E_NETWORK"
}

cmd_test_failures() {
  local pid="${1-}" project="${2-}"
  [[ -n "$pid" ]] || die "usage: test-failures <pipeline_id> [project_path]" 1
  [[ -n "$project" ]] || project=$(derive_project)
  local enc out n
  enc=$(urlencode_path "$project")
  out=$(glab api "projects/$enc/pipelines/$pid/test_report" 2>/dev/null) \
    || die "glab api test_report failed (pid=$pid)" "$E_NETWORK"
  n=$(jq '[ .test_suites[]?.test_cases[]? | select(.status=="failed") ] | length' <<<"$out")
  if [[ "$n" -eq 0 ]]; then
    exit "$E_NOTFOUND"
  fi
  jq '[ .test_suites[]?.test_cases[]?
        | select(.status=="failed")
        | { name, classname, file, execution_time,
            system_output: ((.system_output // "")[0:800]),
            stack_trace:   ((.stack_trace   // "")[0:800]) } ]' <<<"$out"
}

cmd_trace() {
  local jid="${1-}" project="${2-}"
  [[ -n "$jid" ]] || die "usage: trace <job_id> [project_path]" 1
  [[ -n "$project" ]] || project=$(derive_project)
  local enc path host
  enc=$(urlencode_path "$project")
  path="/tmp/gl-trace-${jid}.log"
  if glab api "projects/$enc/jobs/$jid/trace" >"$path" 2>/dev/null && [[ -s "$path" ]]; then
    :
  elif [[ -n "${GITLAB_API_TOKEN-}" ]]; then
    host=$(glab config get host 2>/dev/null || echo "gitlab.com")
    curl -sfH "PRIVATE-TOKEN: $GITLAB_API_TOKEN" \
      "https://$host/api/v4/projects/$enc/jobs/$jid/trace" >"$path" \
      || die "trace download failed (jid=$jid)" "$E_NETWORK"
  else
    die "trace download failed; set GITLAB_API_TOKEN for curl fallback" "$E_NETWORK"
  fi
  [[ -s "$path" ]] || die "trace file empty (jid=$jid)" "$E_NOTFOUND"
  echo "$path"
}

usage() {
  cat <<'USAGE'
fetch-pipeline.sh - read-only GitLab failure fetcher for the debug-gitlab skill.

Usage:
  fetch-pipeline.sh resolve       <URL | branch | "">
  fetch-pipeline.sh failed-jobs   <pipeline_id> [project_path]
  fetch-pipeline.sh test-failures <pipeline_id> [project_path]
  fetch-pipeline.sh trace         <job_id>      [project_path]

project_path may be omitted; falls back to $DEBUG_GITLAB_PROJECT, else the
current repo's glab remote.

Exit codes: 0 ok · 1 usage/other · 2 not found · 3 ambiguous · 4 dep/auth · 5 network
USAGE
}

preflight
case "${1-}" in
  resolve)        shift; cmd_resolve "${1-}" ;;
  failed-jobs)    shift; cmd_failed_jobs "${1-}" "${2-}" ;;
  test-failures)  shift; cmd_test_failures "${1-}" "${2-}" ;;
  trace)          shift; cmd_trace "${1-}" "${2-}" ;;
  ""|-h|--help)   usage ;;
  *)              die "unknown subcommand: $1" 1 ;;
esac
