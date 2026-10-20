#!/usr/bin/env bash
# Usage: mr-compile-failure.sh <repo-dir>
# MR !7 bumps com.acme:clock from 1.4.0 to 2.0.0. Version 2.0.0 removed `Clock.nowMillis()`, and
# the compile job of pipeline 900 fails at Timer.kt:6. The session starts on main.
# Tests: finds the call site, commits the fix, and pushes it. No retry.
. "$(dirname "$0")/../../../../evals/fixture-lib.sh"
host="$1.host"
init_repo "$1"
put gradle/libs.versions.toml <<'EOF'
[versions]
clock = "1.4.0"

[libraries]
clock = { module = "com.acme:clock", version.ref = "clock" }
EOF
put app/src/main/kotlin/acme/Timer.kt <<'EOF'
package acme

import com.acme.clock.Clock

class Timer(private val clock: Clock) {
    fun elapsedMillis(startMillis: Long): Long = clock.nowMillis() - startMillis
}
EOF
commit "Add Timer"
add_origin
git switch -q -c renovate/clock-2.x
sed -i '' 's/1.4.0/2.0.0/' gradle/libs.versions.toml
commit "Update dependency com.acme:clock to v2"
git push -q -u origin renovate/clock-2.x
head=$(git rev-parse HEAD)
git switch -q main
allow_commits

mkdir -p "$host"
url=https://gitlab.example.com/acme/app
jq -n --arg sha "$head" --arg url "$url" '{
  iid: 7, title: "Update dependency com.acme:clock to v2",
  web_url: "\($url)/-/merge_requests/7", source_branch: "renovate/clock-2.x",
  target_branch: "main", state: "opened", draft: false, labels: [],
  author: {username: "renovate-bot"}, head_pipeline: {id: 900, status: "failed", sha: $sha},
  description: "Updates com.acme:clock from 1.4.0 to 2.0.0.\n\nRelease notes 2.0.0:\n- Breaking: `Clock.nowMillis()` is removed. Use `Clock.now().toEpochMilliseconds()`.\n- `Clock.system()` is now `Clock.System`."
}' >"$host/mr.json"
jq -n --arg sha "$head" --arg url "$url" '{
  id: 900, sha: $sha, status: "failed", ref: "renovate/clock-2.x",
  web_url: "\($url)/-/pipelines/900"
}' >"$host/pipeline.json"
jq -n --arg url "$url" '[{id: 9001, name: "compile", stage: "build",
  failure_reason: "script_failure", allow_failure: false, web_url: "\($url)/-/jobs/9001",
  started_at: null, finished_at: null, duration: 80}]' >"$host/jobs.json"
cat >"$host/9001.log" <<'EOF'
$ ./gradlew compileKotlin
> Task :app:compileKotlin FAILED
e: file:///builds/acme/app/app/src/main/kotlin/acme/Timer.kt:6:65 Unresolved reference 'nowMillis'.
FAILURE: Build failed with an exception.
BUILD FAILED in 1m 12s
ERROR: Job failed: exit code 1
EOF
echo "head=$head"
