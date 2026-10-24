# android-capture evals

Trigger and capture evals for the `android-capture` skill, outside a PR draft. The `draft-pr`
evals `ui-capture-suggestion` and `ui-capture-request` test the trigger from a PR draft.

## Files

- `evals.json` - evals, prompts, and checks. The fixture is `draft-ticket`'s `notes-app.sh`.
- `run.py` - builds the repos, runs `claude -p`, and moves the new `~/Downloads/android-*` files
  to `outputs/media/`.
- `grade.py` - the `media_count` and `media_name_regex` check types.

## Run

Start an emulator first. The runs share the device and `~/Downloads`, so use `-j 1`.

```sh
W=~/.ai/ai/evals/android-capture-workspace
./run.py -j 1 --model opus --effort medium $W/iteration-1
```
