#!/usr/bin/env bash
# Usage: gitlab-pipeline.sh check
#        gitlab-pipeline.sh resolve       <URL | branch | "">
#        gitlab-pipeline.sh failed-jobs   <pipeline_id> [project_path]
#        gitlab-pipeline.sh failed-logs   <pipeline_id> [project_path]
#        gitlab-pipeline.sh test-failures <pipeline_id> [project_path]
#        gitlab-pipeline.sh trace         <job_id>      [project_path]
#        gitlab-pipeline.sh signals       <job_id>      [project_path]
# Read-only GitLab pipeline CLI: prereq check, pipeline/job/MR fetch, and trace slicing.
# failed-logs prints the failed-jobs output, then the signals of each job with the verdict
# needs-analysis or unknown. With no project_path, the script uses the glab remote of the repo.
# Exit codes: 0 ok, 1 usage/other, 2 not found, 3 ambiguous, 4 dep/auth, 5 network

set -euo pipefail

die() { echo "gitlab-pipeline: $1" >&2; exit "${2:-1}"; }
# shellcheck source=gitlab-lib.sh
source "$(dirname "$0")/gitlab-lib.sh"

# Local checks first, network last. A missing token and a dirty worktree are only reported.
cmd_check() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not in a git repo" "$E_DEP"
  echo "git-repo: yes"
  command -v glab >/dev/null || die "glab not installed" "$E_DEP"
  echo "glab: ok"
  command -v jq >/dev/null || die "jq not installed" "$E_DEP"
  echo "jq: ok"
  glab auth status >/dev/null 2>&1 \
    || die "glab not authenticated, run \`glab auth login\`" "$E_DEP"
  echo "glab-auth: ok"
  if [[ -n "${GITLAB_API_TOKEN-}" ]]; then
    echo "GITLAB_API_TOKEN: present"
  else
    echo "GITLAB_API_TOKEN: absent (curl trace fallback unavailable)"
  fi
  local dirty
  dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$dirty" -eq 0 ]]; then
    echo "worktree: clean"
  else
    echo "worktree: dirty ($dirty files) - blocks checkout/fix steps only"
  fi
}

# Retries, because 5xx and network errors are often transient.
glab_api_retry() {
  local path="$1" resp err
  err=$(mktemp)
  for _ in 1 2 3; do
    if resp=$(glab api "$path" 2>"$err"); then rm -f "$err"; printf '%s' "$resp"; return 0; fi
    sleep 1
  done
  resp=$(head -c 200 "$err"); rm -f "$err"
  die "glab api failed after retries ($path): $resp" "$E_NETWORK"
}

# Derive the GitLab project_path (group/proj) for the current repo. Order:
# 1) `glab repo view`, 2) git remote URL.
derive_project() {
  local p=""
  p=$(glab repo view --output json 2>/dev/null \
    | jq -r '.fullPath // .path_with_namespace // empty' 2>/dev/null) || p=""
  if [[ -z "$p" || "$p" == "null" ]]; then
    p=$(project_of_url "$(git config --get remote.origin.url 2>/dev/null)")
  fi
  [[ -n "$p" ]] || die "could not derive project_path (pass it as an argument)" 1
  echo "$p"
}

glab_pipeline_view() {
  local pid="$1" project="${2-}" repo_args=()
  [[ -z "$project" ]] || repo_args=(-R "$project")
  glab ci get --pipeline-id "$pid" "${repo_args[@]}" --output json 2>/dev/null \
    || die "glab ci get failed (pid=$pid${project:+ repo=$project})" "$E_NETWORK"
}

mr_target_branch() {
  local iid="$1" project="${2-}" repo_args=()
  [[ -z "$project" ]] || repo_args=(-R "$project")
  glab mr view "$iid" "${repo_args[@]}" --output json 2>/dev/null | jq -r '.target_branch // empty'
}

emit_context() {
  local pjson="$1" project="$2" iid="${3-}"
  local ref target=""
  ref=$(jq -r '.ref // ""' <<<"$pjson")
  if [[ -z "$iid" && "$ref" != refs/merge-requests/* ]]; then
    iid=$(open_mr_of_branch "$ref" "$project")
  fi
  if [[ -n "$iid" ]]; then
    target=$(mr_target_branch "$iid" "$project")
  fi
  jq -nc \
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
  local project="" pid="" pjson="" mr_iid=""

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
    pid=$(glab_api_retry "projects/$enc/jobs/$jid" | jq -r '.pipeline.id // empty')
    [[ -n "$pid" ]] || die "no pipeline for job $jid" "$E_NOTFOUND"
    pjson=$(glab_pipeline_view "$pid" "$project")
  elif [[ "$input" =~ ^https?://[^/]+/(.+)/-/merge_requests/([0-9]+) ]]; then
    project="${BASH_REMATCH[1]}"
    mr_iid="${BASH_REMATCH[2]}"
    local mrjson enc
    mrjson=$(glab mr view "$mr_iid" -R "$project" --output json 2>/dev/null) \
      || die "glab mr view failed (iid=$mr_iid repo=$project)" "$E_NETWORK"
    pid=$(jq -r '.head_pipeline.id // empty' <<<"$mrjson")
    if [[ -z "$pid" ]]; then
      enc=$(urlencode_path "$project")
      pid=$(glab_api_retry "projects/$enc/merge_requests/$mr_iid/pipelines" \
        | jq -r '.[0].id // empty')
      [[ -n "$pid" ]] || die "no pipeline for MR $mr_iid" "$E_NOTFOUND"
    fi
    pjson=$(glab_pipeline_view "$pid" "$project")
  elif [[ "$input" =~ ^[0-9]+$ ]]; then
    die "bare numeric id is ambiguous; pass a full URL (pipelines/jobs/merge_requests)" 1
  else
    project=$(derive_project)
    pjson=$(glab ci get --branch "$input" -R "$project" --output json 2>/dev/null) \
      || die "no pipeline for branch '$input'" "$E_NOTFOUND"
  fi

  emit_context "$pjson" "$project" "$mr_iid"
}

cmd_failed_jobs() {
  local pid="${1-}" project="${2-}"
  [[ -n "$pid" ]] || die "usage: failed-jobs <pipeline_id> [project_path]" 1
  [[ -n "$project" ]] || project=$(derive_project)
  local enc resp; enc=$(urlencode_path "$project")
  resp=$(glab_api_retry "projects/$enc/pipelines/$pid/jobs?scope[]=failed&per_page=100")
  jq -e . >/dev/null 2>&1 <<<"$resp" \
    || die "non-JSON from failed-jobs (pid=$pid): ${resp:0:200}" "$E_NETWORK"
  # `needs-analysis` means that the skill needs the test report or the trace. The skill can write
  # each other verdict without the raw log.
  jq '
    def verdict:
      { "script_failure":             {verdict:"needs-analysis",      action:"analyze"},
        "stuck_or_timeout_failure":   {verdict:"infra-stall",         action:"retry"},
        "runner_system_failure":      {verdict:"infra",               action:"retry"},
        "job_execution_timeout":      {verdict:"hit-timeout",         action:"retry-or-raise-limit"},
        "api_failure":                {verdict:"api-hiccup",          action:"retry"},
        "missing_dependency_failure": {verdict:"upstream-failed",     action:"fix-upstream"},
        "scheduler_failure":          {verdict:"infra",               action:"retry"},
        "archived_failure":           {verdict:"infra",               action:"retry"}
      }[. // ""] // {verdict:"unknown", action:"analyze"};
    [ .[] | . as $j | {
        id, name, stage, failure_reason, allow_failure, web_url,
        started_at, finished_at, duration: (.duration // 0)
      } + ($j.failure_reason | verdict) ]' <<<"$resp"
}

cmd_failed_logs() {
  local pid="${1-}" project="${2-}"
  [[ -n "$pid" ]] || die "usage: failed-logs <pipeline_id> [project_path]" 1
  [[ -n "$project" ]] || project=$(derive_project)
  local jobs; jobs=$(cmd_failed_jobs "$pid" "$project")
  echo "$jobs"
  local id name
  while IFS=$'\t' read -r id name; do
    echo
    echo "== job $id $name =="
    # One missing trace must not hide the signals of the other jobs.
    # A separate process: errexit does not apply on the left side of `||`.
    "$0" signals "$id" "$project" || echo "(signals failed, exit $?)"
  done < <(jq -r '.[] | select(.verdict == "needs-analysis" or .verdict == "unknown")
                  | [.id, .name] | @tsv' <<<"$jobs")
}

cmd_test_failures() {
  local pid="${1-}" project="${2-}"
  [[ -n "$pid" ]] || die "usage: test-failures <pipeline_id> [project_path]" 1
  [[ -n "$project" ]] || project=$(derive_project)
  local enc out n
  enc=$(urlencode_path "$project")
  out=$(glab_api_retry "projects/$enc/pipelines/$pid/test_report")
  jq -e . >/dev/null 2>&1 <<<"$out" \
    || die "non-JSON from test_report (pid=$pid): ${out:0:200}" "$E_NETWORK"
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

# Prints the path of the downloaded trace, /tmp/gl-trace-<jid>.log. The fallback is curl with
# GITLAB_API_TOKEN.
download_trace() {
  local jid="$1" project="$2" enc path host resp
  enc=$(urlencode_path "$project")
  path="/tmp/gl-trace-${jid}.log"
  # Trace is raw log text, not JSON. Reject a bare HTTP-code or JSON error body.
  if resp=$(glab api "projects/$enc/jobs/$jid/trace" 2>/dev/null) \
       && [[ -n "$resp" && ! "$resp" =~ ^[0-9]{3}$ ]] \
       && ! jq -e 'objects | has("message")' >/dev/null 2>&1 <<<"$resp"; then
    printf '%s' "$resp" >"$path"
  elif [[ -n "${GITLAB_API_TOKEN-}" ]]; then
    host=$(glab config get host 2>/dev/null || echo "gitlab.com")
    # The token goes on stdin, because ps shows argv.
    curl -sf -H @- "https://$host/api/v4/projects/$enc/jobs/$jid/trace" \
      <<<"PRIVATE-TOKEN: $GITLAB_API_TOKEN" >"$path" \
      || die "trace download failed (jid=$jid)" "$E_NETWORK"
  else
    die "trace download failed; set GITLAB_API_TOKEN for curl fallback" "$E_NETWORK"
  fi
  [[ -s "$path" ]] || die "trace file empty (jid=$jid)" "$E_NOTFOUND"
  echo "$path"
}

cmd_trace() {
  local jid="${1-}" project="${2-}"
  [[ -n "$jid" ]] || die "usage: trace <job_id> [project_path]" 1
  [[ -n "$project" ]] || project=$(derive_project)
  download_trace "$jid" "$project"
}

# The skill reads these bounded parts of the trace, not the full log. The line numbers of the hot
# lines are for a sed follow-up.
cmd_signals() {
  local jid="${1-}" project="${2-}"
  [[ -n "$jid" ]] || die "usage: signals <job_id> [project_path]" 1
  [[ -n "$project" ]] || project=$(derive_project)
  local path
  path=$(download_trace "$jid" "$project")

  echo "== trace: $path =="
  echo
  echo "== tail (last 200) =="
  tail -n 200 "$path"
  echo
  echo "== hot lines (line:match, last 60) =="
  grep -nE -i '(^|\s)(error|fail(ed|ure)?|exception|fatal|panic|traceback|killed|exited with code [^0])' \
    "$path" | tail -n 60 || echo "(none)"
  echo
  echo "== step boundaries (\$ cmd) =="
  # GitLab prefixes each shell command with "$ ", often after an ANSI reset.
  local step_pat=$'^(\x1b\\[[0-9;]*[A-Za-z])*[[:space:]]*\\$ '
  grep -nE "$step_pat" "$path" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' || echo "(none)"
}

case "${1-}" in
  check)          cmd_check ;;
  resolve)        preflight; shift; cmd_resolve "${1-}" ;;
  failed-jobs)    preflight; shift; cmd_failed_jobs "${1-}" "${2-}" ;;
  failed-logs)    preflight; shift; cmd_failed_logs "${1-}" "${2-}" ;;
  test-failures)  preflight; shift; cmd_test_failures "${1-}" "${2-}" ;;
  trace)          preflight; shift; cmd_trace "${1-}" "${2-}" ;;
  signals)        preflight; shift; cmd_signals "${1-}" "${2-}" ;;
  *)              die "unknown subcommand '${1-}': read the # Usage: lines in $0" 1 ;;
esac
