# When the agent session is gone for the grace period, the comment goes to the hub as an open item.
agent stop stack
wait_until "the agent record of the stack ends" record_gone stack
event stack '{"kind": "comment", "iid": 4, "title": "Add part B",
  "url": "https://gitlab.example.com/sample/repo/-/merge_requests/4#note_21", "actor": "anna",
  "detail": "Please add a test for part B.", "branch": "feature-b", "item": "thread:d21"}'
