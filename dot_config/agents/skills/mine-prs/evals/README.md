# mine-prs evals

Regression evals for the `mine-prs` skill. The eval builds a small Kotlin repo with a fake review
history of 8 merged MRs, runs `/mine-prs` in it with headless `claude -p`, and grades the findings
file, the glab calls, and the transcript with fixed checks.

## Files

- `evals.json` - evals, prompts, and checks.
- `fixtures/review-history.sh` - the repo builder. The header comment lists the planted topics.
- `fixtures/history.json` - the MRs, threads, and compare diffs. `../prs.test.sh` uses it too.
- `shims/glab` - `run.py` puts it on PATH. It answers from `<repo>.host/history.json` and logs each
  call to `<repo>.host/calls.log`.
- `run.py` - builds the repos, runs `claude -p`, copies the findings files and the glab calls to
  `outputs/`, and grades.
- `grade.py` - findings and glab-call check types.

The shared harness and `compare.py` are in `~/.config/agents/evals/`.

## Run

```sh
W=~/.ai/ai/evals/mine-prs-workspace
./run.py -n 2 --model opus --effort medium $W/iteration-1
./grade.py $W/iteration-1
```

One run costs one full skill session.
