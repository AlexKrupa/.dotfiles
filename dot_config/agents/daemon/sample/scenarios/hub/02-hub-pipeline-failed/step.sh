# A job that fails in its script makes the router ask the model, so the hub item stays open.
engine_state hub '{"needs": ["main-failed"]}'
event hub '{"kind": "default-failed", "iid": null, "title": null,
  "url": "https://gitlab.example.com/sample/repo/-/pipelines/88", "actor": "",
  "detail": "pipeline 88 failed", "branch": "main", "previous": "success",
  "item": "main-failed:main", "jobs": ["unit-tests"],
  "failed": [{"id": 501, "name": "unit-tests", "failure_reason": "script_failure"}]}'
