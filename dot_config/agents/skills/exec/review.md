# exec review phase

This session starts with only the plan path. `review-me` gets its inputs from the plan, the spec in
its `**Spec:**` line, and the branch diff. Thus the review does not need the execution session.

1. Read `~/.config/agents/skills/review-me/SKILL.md` and follow it in auto mode in this session,
   with the plan path.
2. If the `review-me` verdict is "ready to push", run `draft-pr`. If it needs the user's decision,
   or the validation failed, stop. After the user answers and the fixes are in, run `draft-pr`.
3. If `draft-pr` stops at its preflight (no git repo, mainline branch), end with the `review-me`
   reply.
