# draft-pr evals

Regression evals for the `draft-pr` skill. Each eval builds a small notes-app repo, runs
`/draft-pr` in it with headless `claude -p`, and grades the PR file, the branch state, the final
reply, and the transcript with fixed checks.

## Files

- `evals.json` - evals, prompts, checks, and pattern sets. `common_checks` apply to every eval
  unless it sets `"common": false` or lists ids in `common_skip`.
- `fixtures/*.sh` - one repo builder per eval. The header comment lists what the eval tests. The
  base repo is `draft-ticket`'s `notes-app.sh`.
- `run.py` - builds the repos, runs `claude -p`, copies the PR file from `~/.ai/<repo-slug>/prs/`
  to `outputs/prs/`, writes `outputs/git-state.txt`, deletes `~/.ai/<repo-slug>/`, and grades.
- `grade.py` - PR and branch-state check types. Writes `grading.json` for skill-creator's viewer.

The shared harness, `compare.py`, and the fixture helpers are in `~/.config/ai/evals/`.

## Run

```sh
W=~/.ai/ai/evals/draft-pr-workspace
./run.py --model opus --effort medium $W/iteration-1              # 4 evals x 3 runs, live skill
./run.py --model opus --effort medium $W/iteration-1 stack-fixup  # one eval
~/.config/ai/evals/compare.py $W/iteration-1 $W/iteration-2
```

Use Opus with `--effort medium`. It is the usual setup for PR work.

`stack-fixup` changes the fixture repo on purpose (sync, restack, squash). It has no
`repo_unchanged` check. Its `state_*` checks test the branch state.

`run.py` needs `claude -p` with `--permission-mode dontAsk` and an allowlist (`ALLOWED_TOOLS`).
Start it from your own shell, or with `!` in Claude Code.

To see the outputs, run skill-creator's `eval-viewer/generate_review.py` on the iteration dir.
