# draft-ticket evals

Regression evals for the `draft-ticket` skill. Each eval builds a small notes-app repo, runs
`/draft-ticket` in it with headless `claude -p`, and grades the ticket file, the final reply, and
the transcript with fixed checks.

## Files

- `evals.json` - evals, prompts, checks, and pattern sets. `common_checks` apply to every eval
  unless it sets `"common": false` or lists ids in `common_skip`.
- `fixtures/*.sh` - one repo builder per eval. The header comment lists what the eval tests.
- `run.py` - builds the repos, runs `claude -p`, copies the ticket from `~/.ai/<repo-slug>/tickets/`
  to `outputs/tickets/`, deletes `~/.ai/<repo-slug>/`, and grades.
- `grade.py` - ticket check types, and `repo_*` checks that run a command in the fixture repo.
  Writes `grading.json` for skill-creator's viewer.

The shared harness, `compare.py`, and the fixture helpers are in `~/.config/ai/evals/`.

## Run

```sh
W=~/.ai/ai/evals/draft-ticket-workspace
./run.py --effort medium $W/iteration-1                    # 7 evals x 3 runs, live skill
./run.py --effort medium $W/iteration-1 post-factum-branch # one eval
~/.config/ai/evals/compare.py $W/iteration-1 $W/iteration-2
```

Use `--effort medium`. It is the usual effort for ticket work.

The checks cannot test an interview, because `claude -p` gets one prompt only. The prompts of all
evals except `no-context-asks` contain all the context, so the skill must write the ticket with
no questions. `no-context-asks` only checks that the skill asks before it writes a file. The
`ticket-id-rename` evals give the real ticket id in the prompt, as a caller skill does after the
publish.

The `done` patterns can match a correct sentence, for example "Users who already have notes".
Read a failed match before you change the skill.

`run.py` needs `claude -p` with `--permission-mode dontAsk` and an allowlist (`ALLOWED_TOOLS`).
Start it from your own shell, or with `!` in Claude Code.

To see the outputs, run skill-creator's `eval-viewer/generate_review.py` on the iteration dir.
