# bump evals

Regression evals for the `bump` skill. Each eval builds a small Kotlin repo with a bump branch,
runs `/bump` in it with headless `claude -p`, and grades the reply, the branch state, the glab
calls, and the transcript with fixed checks.

## Files

- `evals.json` - evals, prompts, and checks.
- `fixtures/*.sh` - one repo builder per eval. The header comment lists what the eval tests. The
  fixture also writes the fake MR, pipeline, failed jobs, and job log to `<repo>.host/`.
- `shims/glab` - `run.py` puts it on PATH. It answers from `<repo>.host/` and logs each call to
  `<repo>.host/calls.log`. At the first GraphQL call, it stops the watch client with exit 3.
- `run.py` - builds the repos, runs `claude -p`, writes `outputs/glab-calls.log` and
  `outputs/git-state.txt`, and grades. The runs use a temp `XDG_STATE_HOME`, so their watch daemon
  is not the real daemon.
- `grade.py` - branch-state and glab-call check types.

The shared harness and `compare.py` are in `~/.config/agents/evals/`.

## Run

```sh
W=~/.ai/ai/evals/bump-workspace
./run.py -n 1 --model opus --effort medium $W/iteration-1
./grade.py $W/iteration-1
```

One run costs one full skill session. Use `-n 1` unless the result is not stable.
