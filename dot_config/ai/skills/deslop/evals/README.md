# deslop evals

Regression evals for the `deslop` skill. Each eval builds a small git repo with seeded slop, runs
`/deslop` in it with headless `claude -p`, and applies the fixups with
`git rebase -i --autosquash` in a clone. Fixed checks grade the files and the history after the
rebase, the final reply, and the transcript.

## Files

- `evals.json` - evals, prompts, checks, and the `slop` pattern set. `common_checks` apply to every
  eval unless it sets `"common": false` or lists ids in `common_skip`.
- `fixtures/*.sh` - one repo builder per eval. The header comment lists the seeded slop and the
  facts to keep.
- `run.py` - builds the repos, runs `claude -p`, applies the fixups in `<run-dir>/applied/`, and
  grades.
- `grade.py` - file, comment, and history check types. Writes `grading.json` for skill-creator's
  viewer.

The shared harness, `compare.py`, and the fixture helpers are in `~/.config/ai/evals/`.

## Run

```sh
W=~/.ai/ai/evals/deslop-workspace
./run.py $W/iteration-2              # 5 evals x 3 runs, live skill
./run.py $W/iteration-2 branch-slop  # one eval
~/.config/ai/evals/compare.py $W/iteration-1 $W/iteration-2
```

Run the full set before and after a change to the skill, then compare the two iterations. A drop
of one run in three can be noise. Run that eval again before you act on it.

The checks look for the words that the fixtures seed, not for the live banned list in
`~/.config/ai/AGENTS.md`. Add a word to `pattern_sets.slop` and to a fixture to cover it.

`run.py` needs `claude -p` with `--permission-mode dontAsk` and an allowlist (`ALLOWED_TOOLS`).
Start it from your own shell, or with `!` in Claude Code.

To see the outputs, run skill-creator's `eval-viewer/generate_review.py` on the iteration dir.
