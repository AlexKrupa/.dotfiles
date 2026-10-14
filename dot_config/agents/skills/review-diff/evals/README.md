# review-diff evals

Regression evals for the `review-diff` skill. Each eval builds a small git repo with known
defects, runs `/review-diff` in it with headless `claude -p`, and grades the report, the final
reply, and the transcript with fixed checks.

## Files

- `evals.json` - evals, prompts, and checks. `common_checks` apply to every eval unless it sets
  `"common": false` or lists ids in `common_skip`.
- `fixtures/*.sh` - one repo builder per eval. The header comment lists the seeded defects.
- `run.py` - builds the repos, runs `claude -p`, moves the reports out of `~/.ai/`, and grades.
- `grade.py` - report check types and grading. Writes `grading.json` for skill-creator's viewer.
- `helpers.test.sh` - tests for `bin/git-diff-context.sh`, `docs-index.sh`,
  `bin/review-report-path.sh`. No LLM.

The shared harness, `compare.py`, and the fixture helpers are in `~/.config/ai/evals/`.

## Run

```sh
W=~/.ai/ai/evals/review-diff-workspace
./helpers.test.sh
./run.py $W/iteration-2              # 10 evals x 3 runs, live skill
./run.py $W/iteration-2 fan-out      # 23-file fan-out eval, slow
~/.config/ai/evals/compare.py $W/iteration-1 $W/iteration-2
```

Each run is a full audit, so select the evals for the change:

- Evals for the changed rules: 3 runs (`-n 3`). Name them on the command line.
- Other evals, as a regression check for a change to `SKILL.md`: 1 run (`-n 1`).
- A change only to a rules file that one step reads (e.g. `structure-diagram.md`): its evals only.
- The full set at `-n 3`: only for a large change to the audit flow.

Compare the iteration with the last one. A drop of one run in three can be noise. Run that eval
again before you act on it.

`run.py` needs `claude -p` with `--permission-mode dontAsk` and an allowlist (`ALLOWED_TOOLS`).
Start it from your own shell, or with `!` in Claude Code.

To see the outputs, run skill-creator's `eval-viewer/generate_review.py` on the iteration dir.
