# MR 3 merges with a squash commit, and the reviewer changed a.txt in the merge. The conflict test
# of feature-b then skips the commits of feature-a, so a.txt gives no conflict. The event goes
# first: the new origin/main starts the conflict test again.
event stack '{"kind": "merged", "iid": 3, "title": "Add part A",
  "url": "https://gitlab.example.com/sample/repo/-/merge_requests/3", "actor": "anna",
  "detail": "merged", "branch": "feature-a"}'
settle
origin_commit main a.txt "Add part A, reviewed"
