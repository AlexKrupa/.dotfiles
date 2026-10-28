# A default-branch job fails with a runner failure. The router of the live hub agent retries it 2
# times, and it passes at the second retry. No job fails in its script, so no agent starts.
agent start hub
retry 601 '{"id": 602, "name": "unit-tests", "status": "pending", "failure_reason": null}'
job 602 '{"id": 602, "name": "unit-tests", "status": "running", "failure_reason": null}' \
  '{"id": 602, "name": "unit-tests", "status": "failed", "failure_reason": "runner_system_failure"}'
retry 602 '{"id": 603, "name": "unit-tests", "status": "pending", "failure_reason": null}'
job 603 '{"id": 603, "name": "unit-tests", "status": "success", "failure_reason": null}'
event hub '{"kind": "default-failed", "iid": null, "title": null,
  "url": "https://gitlab.example.com/sample/repo/-/pipelines/92", "actor": "",
  "detail": "pipeline 92 failed", "branch": "main", "previous": "success",
  "item": "main-failed:main", "jobs": ["unit-tests"],
  "failed": [{"id": 601, "name": "unit-tests", "failure_reason": "runner_system_failure"}]}'
settle
wait_until "the retried job passes" grep -q "passed after retry" "$SAMPLE_STATE/watchd/items/repo.board"
if grep -q start_agent "$SAMPLE_STATE/workspaces/calls" 2>/dev/null; then
  echo "an agent started for a runner failure" >&2
  exit 1
fi
