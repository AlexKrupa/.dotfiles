# MR 9 is mine and has no worktree: the hub state lists it, and the own target checks it.
engine_state hub '{"needs": [], "own_mrs": [{"iid": 9}]}'
settle
event own '{"kind": "comment", "iid": 9, "title": "Fix the login timeout",
  "url": "https://gitlab.example.com/sample/repo/-/merge_requests/9#note_41", "actor": "bob",
  "detail": "Looks good, one question.", "branch": "fix-login", "item": "thread:d41"}'
