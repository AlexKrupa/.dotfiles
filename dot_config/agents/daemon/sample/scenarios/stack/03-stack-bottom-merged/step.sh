# The squash commit has a different a.txt, which conflicts only if the test keeps the commits of
# feature-a. The event goes first, because the new origin/main starts the conflict test again.
event stack '{"kind": "merged", "iid": 3, "title": "Add part A",
  "url": "https://gitlab.example.com/sample/repo/-/merge_requests/3", "actor": "anna",
  "detail": "merged", "branch": "feature-a"}'
settle
origin_commit main a.txt "Add part A, reviewed"
