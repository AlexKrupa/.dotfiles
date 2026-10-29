old=$(git -C "$SAMPLE_ROOT/repo-review" rev-parse HEAD)
origin_commit review-7 r.txt "Fix part R"
new=$(git -C "$origin" rev-parse review-7)
base=$(git -C "$origin" rev-parse main)
engine_state review '{"needs": ["commits", "reply"]}'
event review "$(jq -nc --arg old "$old" --arg new "$new" --arg base "$base" '{kind: "pushed",
  iid: 7, title: "Add part R", url: "https://gitlab.example.com/sample/repo/-/merge_requests/7",
  actor: "", detail: "pushed \($new[:8])", branch: "review-7", old_base: $base, old_head: $old,
  new_base: $base, new_head: $new}')"
event review '{"kind": "comment", "iid": 7, "title": "Add part R",
  "url": "https://gitlab.example.com/sample/repo/-/merge_requests/7#note_31", "actor": "anna",
  "detail": "Done, I renamed the helper.", "branch": "review-7", "item": "thread:d31"}'
