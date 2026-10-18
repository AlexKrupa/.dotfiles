#!/usr/bin/env bash
# Usage: hub-retry.sh <job-id> [--interval SECONDS] [--timeout SECONDS]
# Retries a GitLab job of the repo in the current directory, and waits until the new job finishes.
# Each interval, it reads the status of the new job. Then it prints one JSON line: job_id,
# new_job_id, name, status, failure_reason (null for a job that passed), web_url.
# Defaults: --interval 30, --timeout 3600.
# Exit codes: 0 the new job finished with any status, 1 error, 4 the new job did not finish before
# the timeout.
set -euo pipefail

die() { echo "hub-retry: $1" >&2; exit 1; }

job=''
interval=30
timeout=3600
while (($#)); do
  case "$1" in
    --interval) [[ $# -ge 2 ]] || die "--interval needs seconds"; interval=$2; shift 2 ;;
    --timeout) [[ $# -ge 2 ]] || die "--timeout needs seconds"; timeout=$2; shift 2 ;;
    *) [[ -z $job && $1 =~ ^[0-9]+$ ]] || die "unexpected argument: $1"; job=$1; shift ;;
  esac
done
[[ -n $job ]] || die "usage: hub-retry.sh <job-id> [--interval SECONDS] [--timeout SECONDS]"

command -v jq >/dev/null || die "jq is not installed"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

resp=$(glab api -X POST "projects/:id/jobs/$job/retry" 2>"$tmp/stderr") \
  || die "retry of job $job failed: $(paste -s -d ' ' "$tmp/stderr")"
new=$(jq -er .id <<<"$resp") || die "retry of job $job: no job id in the response"

deadline=$(($(date +%s) + timeout))
while :; do
  sleep "$interval"
  resp=$(glab api "projects/:id/jobs/$new" 2>"$tmp/stderr") \
    || die "status of job $new failed: $(paste -s -d ' ' "$tmp/stderr")"
  status=$(jq -r .status <<<"$resp")
  case "$status" in
    success | failed | canceled | skipped)
      jq -c --argjson old "$job" '{job_id: $old, new_job_id: .id, name, status,
        failure_reason: (if .status == "success" then null else .failure_reason end), web_url}' \
        <<<"$resp"
      exit 0 ;;
  esac
  if (($(date +%s) >= deadline)); then
    echo "hub-retry: job $new did not finish in $timeout seconds, status $status" >&2
    exit 4
  fi
done
