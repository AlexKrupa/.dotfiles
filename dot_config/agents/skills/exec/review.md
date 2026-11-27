# exec review phase

This session starts with only a plan path or a spec path. `review-me` gets its inputs from the
plan, the spec in its `**Spec:**` line or the spec path, the open findings of a plan execution,
and the branch diff. Thus the review does not need the session that wrote the code.

1. With a spec path, skip this step. Run `<skill folder>/open-findings.sh '<plan path>'`. The first output line is the plan
   workspace of the superpowers execution. The second line is the open findings file: the
   deferred findings and the rulings of the execution ledger. If the plan has no workspace, the
   output is empty. If the ledger has no such lines, the second line is missing.
2. Read `~/.config/agents/skills/review-me/SKILL.md` and follow it in auto mode in this session,
   with the plan or spec path and the open findings path.
3. If the `review-me` verdict is "ready to push", run `draft-pr`. If it needs the user's decision,
   or the validation failed, stop. After the user answers and the fixes are in, run `draft-pr`.
4. If `draft-pr` stops at its preflight (no git repo, mainline branch), end with the `review-me`
   reply.
5. If step 1 printed an open findings file, list each of its `Ruling:` lines in the final reply,
   under "Rulings of the execution", word for word. The execution session made these decisions for the user, and its
   reply is gone after the clear.
6. After step 3 or step 4 ends the review, delete the plan workspace with `rm -rf '<workspace>'`.
   Delete only the path of step 1. If step 1 printed no workspace, skip this step. If the review
   stops for the user, keep the workspace.
