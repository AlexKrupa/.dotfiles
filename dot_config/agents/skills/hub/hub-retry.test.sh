#!/usr/bin/env bash
# Checks hub-retry.sh with a fake glab.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/hub-retry.sh"
d=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$d"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake glab: the POST prints $MOCK_DIR/post.json. Each GET prints the next line of
# $MOCK_DIR/get.jsonl, and the last line again after the end.
# MOCK_POST_FAIL and MOCK_GET_FAIL: the call writes the value on stderr and fails.
mkdir -p "$d/bin" "$d/mock"
cat >"$d/bin/glab" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_LOG"
case "$*" in
  "api -X POST projects/:id/jobs/"*/retry)
    if [ -n "${MOCK_POST_FAIL:-}" ]; then echo "$MOCK_POST_FAIL" >&2; exit 1; fi
    cat "$MOCK_DIR/post.json" ;;
  "api projects/:id/jobs/"*)
    if [ -n "${MOCK_GET_FAIL:-}" ]; then echo "$MOCK_GET_FAIL" >&2; exit 1; fi
    n=$(($(cat "$MOCK_DIR/count" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$MOCK_DIR/count"
    lines=$(wc -l <"$MOCK_DIR/get.jsonl")
    [ "$n" -le "$lines" ] || n=$lines
    sed -n "${n}p" "$MOCK_DIR/get.jsonl" ;;
  *) echo "unexpected glab call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$d/bin/glab"
export PATH="$d/bin:$PATH" MOCK_DIR="$d/mock" MOCK_LOG="$d/log"

url=https://gitlab.example.com/group/app/-/jobs/12
job() { # status, failure_reason (JSON)
  echo '{"id": 12, "name": "build", "status": "'"$1"'", "failure_reason": '"$2"',
    "web_url": "'"$url"'"}' | jq -c .
}
setup() { # GET responses, one for each argument
  rm -f "$d/mock/count" "$d/log"
  echo '{"id": 12, "name": "build", "status": "pending"}' >"$d/mock/post.json"
  printf '%s\n' "$@" >"$d/mock/get.jsonl"
}
run() { # Sets out, err, and code.
  out=$("$script" "$@" 2>"$d/err"); code=$?
  err=$(cat "$d/err")
}

setup "$(job running null)" "$(job success null)"
run 11 --interval 0
check "retry, then success: output" \
  '{"job_id":11,"new_job_id":12,"name":"build","status":"success","failure_reason":null,"web_url":"'"$url"'"}' \
  "$out"
check "retry, then success: exit 0" 0 "$code"
check "retry, then success: POST" "api -X POST projects/:id/jobs/11/retry" "$(head -1 "$d/log")"
check "retry, then success: GET of the new job" "api projects/:id/jobs/12" "$(sed -n 2p "$d/log")"

setup "$(job failed '"runner_system_failure"')"
run 11 --interval 0
check "retry, then failed: exit 0" 0 "$code"
check "retry, then failed: status" failed "$(jq -r .status <<<"$out")"
check "retry, then failed: reason" runner_system_failure "$(jq -r .failure_reason <<<"$out")"

setup "$(job success null)"
MOCK_POST_FAIL='429 Too Many Requests' run 11 --interval 0
check "POST fails: exit 1" 1 "$code"
check "POST fails: message" "hub-retry: retry of job 11 failed: 429 Too Many Requests" "$err"

setup "$(job success null)"
MOCK_GET_FAIL='dial tcp: connection refused' run 11 --interval 0
check "GET fails: exit 1" 1 "$code"
check "GET fails: message" "hub-retry: " "${err:0:11}"

setup "$(job pending null)"
run 11 --interval 0 --timeout 0
check "timeout: exit 4" 4 "$code"
check "timeout: names the new job" yes "$(grep -q 'job 12' <<<"$err" && echo yes)"

run
check "no job id: exit 1" 1 "$code"
check "no job id: message" "hub-retry: " "${err:0:11}"

exit "$fail"
