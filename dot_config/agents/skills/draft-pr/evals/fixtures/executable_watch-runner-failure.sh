#!/usr/bin/env bash
# Usage: watch-runner-failure.sh <repo-dir>
# watch-stack.sh, and pipeline 503 of !12 failed because the runner lost its connection.
# Tests: one retry of job 9003, no fix, no push.
"$(dirname "$0")/watch-stack.sh" "$1"
cat >"$1.host/logs/503.log" <<'EOF'
Job 9003 (assemble) failed:
Running with gitlab-runner 17.4.0 on docker-runner-12
Preparing the "docker" executor
ERROR: Job failed (system failure): error during connect: Post "http://docker:2375/v1.44/containers/create": dial tcp 10.0.3.7:2375: connect: connection refused
EOF
