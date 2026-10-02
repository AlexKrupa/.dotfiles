# review-branch evals

Regression evals for the `review-branch` skill. Each eval builds a small git repo with known
defects, runs `/review-branch` in it with headless `claude -p`, and grades the report, the final
reply, and the transcript with fixed checks.

## Files

- `evals.json` - evals, prompts, and checks. `common_checks` apply to every eval unless it sets
  `"common": false` or lists ids in `common_skip`.
- `fixtures/*.sh` - one repo builder per eval. The header comment lists the seeded defects.
- `run.py` - builds the repos, runs `claude -p`, moves the reports out of `~/.ai/`, and grades.
- `grade.py` - check types and grading. Writes `grading.json` for skill-creator's viewer.
- `compare.py` - per-check pass rates of two iterations. Exits 1 on a regression.
- `helpers.test.sh` - tests for `branch-context.sh`, `docs-index.sh`, `report-path.sh`. No LLM.

## Run

```sh
W=~/.ai/ai/evals/review-branch-workspace
./helpers.test.sh
./run.py $W/iteration-2              # 8 evals x 3 runs, live skill
./run.py $W/iteration-2 fan-out      # 23-file fan-out eval, slow
./compare.py $W/iteration-1 $W/iteration-2
```

Run the full set before and after a change to the skill, then compare the two iterations. A drop
of one run in three can be noise. Run that eval again before you act on it.

`run.py` needs `claude -p` with `--permission-mode dontAsk` and an allowlist (`ALLOWED_TOOLS`).
Start it from your own shell, or with `!` in Claude Code.

To see the outputs, run skill-creator's `eval-viewer/generate_review.py` on the iteration dir.
