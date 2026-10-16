#!/usr/bin/env bash
# Code host calls for the bump skill. Only GitLab works now. A second host gets its own branch
# in each subcommand.
# Subcommands: mr | ci | failures | retry
# Exit codes: 0 ok, 1 usage/other, 2 not found, 4 unsupported host / missing dep / auth,
# 5 network, 6 wait timeout
set -euo pipefail

BIN=~/.config/agents/bin
IN_PROGRESS='^(created|waiting_for_resource|preparing|pending|running|scheduled)$'

die() { echo "bump-host: $1" >&2; exit "${2:-1}"; }

host() {
  if command -v glab >/dev/null && glab repo view >/dev/null 2>&1; then
    echo gitlab
  else
    die "unsupported code host (only GitLab works now); ask the user for the CI state" 4
  fi
}

# mr <PR/MR URL | branch>: the MR as JSON, with source_branch, target_branch, web_url,
# description.
cmd_mr() {
  [[ -n "${1-}" ]] || die "usage: mr <PR/MR URL | branch>"
  case "$HOST" in
    gitlab) "$BIN/fetch-gitlab-mr.sh" resolve "$1" ;;
  esac
}

# ci <PR/MR URL | branch> [--wait] [--sha SHA]: the latest pipeline as JSON, with
# pipeline_id, sha, status, web_url, project_path.
# --wait: poll every 60 s until the pipeline is done. With --sha, also wait until the pipeline
# is for that commit. Stops with exit 6 after 90 min.
cmd_ci() {
  local target="" wait=0 sha="" json status deadline=$((SECONDS + 5400))
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --wait) wait=1 ;;
      --sha) sha="${2-}"; shift ;;
      *) target="$1" ;;
    esac
    shift
  done
  [[ -n "$target" ]] || die "usage: ci <PR/MR URL | branch> [--wait] [--sha SHA]"
  while :; do
    if json=$("$BIN/gitlab-pipeline.sh" resolve "$target" 2>/dev/null); then
      status=$(jq -r .status <<<"$json")
      if [[ $wait == 0 ]] \
        || { [[ -z "$sha" || $(jq -r .sha <<<"$json") == "$sha" ]] \
          && ! [[ "$status" =~ $IN_PROGRESS ]]; }; then
        echo "$json"
        return
      fi
    elif [[ $wait == 0 ]]; then
      die "no pipeline for $target" 2
    fi
    ((SECONDS < deadline)) || die "pipeline not done after 90 min: $target" 6
    sleep 60
  done
}

# failures <pipeline_id> [project_path]: the failed jobs with a verdict, and the log signals of
# each job that needs analysis.
cmd_failures() {
  [[ -n "${1-}" ]] || die "usage: failures <pipeline_id> [project_path]"
  case "$HOST" in
    gitlab) "$BIN/gitlab-pipeline.sh" failed-logs "$@" ;;
  esac
}

# retry <job_id> [project_path]: runs one failed job again.
cmd_retry() {
  [[ -n "${1-}" ]] || die "usage: retry <job_id> [project_path]"
  case "$HOST" in
    gitlab) glab ci retry "$1" ${2:+-R "$2"} || die "glab ci retry failed (job=$1)" 5 ;;
  esac
}

case "${1-}" in
  mr|ci|failures|retry) HOST=$(host) ;;
esac

case "${1-}" in
  mr)       shift; cmd_mr "$@" ;;
  ci)       shift; cmd_ci "$@" ;;
  failures) shift; cmd_failures "$@" ;;
  retry)    shift; cmd_retry "$@" ;;
  *)
    cat <<'USAGE'
bump-host.sh - code host calls for the bump skill (GitLab only now).

Usage:
  bump-host.sh mr       <PR/MR URL | branch>
  bump-host.sh ci       <PR/MR URL | branch> [--wait] [--sha SHA]
  bump-host.sh failures <pipeline_id> [project_path]
  bump-host.sh retry    <job_id> [project_path]

Exit codes: 0 ok, 1 usage/other, 2 not found, 4 unsupported host / dep / auth, 5 network,
6 wait timeout
USAGE
    [[ -z "${1-}" || "$1" == -h || "$1" == --help ]] || exit 1
    ;;
esac
