# review-pr evals

Regression evals for the Watch step of the `review-pr` skill. Each eval builds a small
notes-app repo with a reviewed MR branch and a review report. It runs the prompt with headless
`claude -p`. Fixed checks grade the report, the branch state, the reply of the first turn, and
the transcript.

## Files

- `evals.json` - evals, prompts, checks, and pattern sets. `common_checks` apply to every eval
  unless it sets `"common": false` or lists ids in `common_skip`.
- `fixtures/*.sh` - one repo builder per eval. The header comment tells what the eval tests.
  `review-base.sh` writes the review report to `~/.ai/<repo-slug>/reviews/`.
- `run.py` - builds the repos, runs `claude -p`, copies the reports to `outputs/reviews/`, writes
  `outputs/git-state.txt`, deletes `~/.ai/<repo-slug>/`, and grades. The runs use a temp
  `XDG_STATE_HOME`, so their watch daemon is not the real daemon.
- `shims/glab` - `run.py` puts it on PATH. It stops each watch at its first GitLab call, with
  exit 3.
- `grade.py` - report and branch-state check types. Writes `grading.json` for skill-creator's
  viewer.

The shared `harness.py`, `compare.py`, and the fixture helpers are in `~/.config/agents/evals/`.

## Run

```sh
W=~/.ai/ai/evals/review-pr-workspace
./run.py --model opus --effort medium $W/iteration-1                # 6 evals x 3 runs
./run.py --model opus --effort medium $W/iteration-1 watch-amend    # one eval
~/.config/agents/evals/compare.py $W/iteration-1 $W/iteration-2
```

`git fetch` changes the remote-tracking refs, so the evals have no `repo_unchanged` check. The
`branch-stays` check tests the local branch and the working tree.

`run.py` needs `claude -p` with `--permission-mode dontAsk` and an allowlist (`ALLOWED_TOOLS`).
Start it from your own shell, or with `!` in Claude Code.
