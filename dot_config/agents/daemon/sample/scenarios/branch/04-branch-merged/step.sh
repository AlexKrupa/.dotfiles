# MR 5 merges into main. The daemon fast-forwards the main checkout.
git -C "$SAMPLE_ROOT/repo-branch" push -q origin HEAD:main
engine_state branch '{"needs": []}'
event branch '{"kind": "merged", "iid": 5, "title": "Add feature",
  "url": "https://gitlab.example.com/sample/repo/-/merge_requests/5", "actor": "anna",
  "detail": "merged", "branch": "feature"}'
