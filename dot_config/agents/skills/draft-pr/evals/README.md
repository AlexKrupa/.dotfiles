# draft-pr evals

Regression evals for the `draft-pr` skill. Each eval builds a small notes-app repo, runs
`/draft-pr` in it with headless `claude -p`, and grades the PR file, the branch state, the reply
of the first turn, and the transcript with fixed checks.

## Files

- `evals.json` - evals, prompts, checks, and pattern sets. `common_checks` apply to every eval
  unless it sets `"common": false` or lists ids in `common_skip`.
- `fixtures/*.sh` - one repo builder per eval. The header comment lists what the eval tests. The
  base repo is `draft-ticket`'s `notes-app.sh`.
- `run.py` - builds the repos, runs `claude -p`, copies the PR file from `~/.ai/<repo-slug>/prs/`
  to `outputs/prs/`, writes `outputs/git-state.txt`, deletes `~/.ai/<repo-slug>/`, and grades.
- `shims/git-spice` - `run.py` puts it on PATH. In the fixture repos, `submit` succeeds with no
  forge, and `log --json` gets `change` objects from `<repo>.changes.json`.
- `grade.py` - PR and branch-state check types. Writes `grading.json` for skill-creator's viewer.

The shared harness, `compare.py`, and the fixture helpers are in `~/.config/agents/evals/`.

## Run

```sh
W=~/.ai/ai/evals/draft-pr-workspace
./run.py --model opus --effort medium $W/iteration-1              # 10 evals x 3 runs, live skill
./run.py --model opus --effort medium $W/iteration-1 stack-fixup  # one eval
~/.config/agents/evals/compare.py $W/iteration-1 $W/iteration-2
```

Use Opus with `--effort medium`. It is the usual setup for PR work.

`stack-fixup` and `untracked-stack` change the fixture repo on purpose (track, sync, restack,
squash). They have no `repo_unchanged` check. Their `state_*` checks test the branch state.

The `watch-*` evals test the Watch step. Each prompt has the output of one watch result. Each
fixture has fake wrapper commands in `<repo>.host/`. They have `"common": false`, because they
write no PR file. `watch-lint` changes the fixture repo on purpose.

`run.py` needs `claude -p` with `--permission-mode dontAsk` and an allowlist (`ALLOWED_TOOLS`).
Start it from your own shell, or with `!` in Claude Code.

To see the outputs, run skill-creator's `eval-viewer/generate_review.py` on the iteration dir.
