# Instruction evals

These evals find the rules of `instructions-agents.md` that the model follows with no
instruction. Each probe task runs under two conditions: no `CLAUDE.md` (`none`), and the
`CLAUDE.md` of daily use (`full`). A rule that passes with no instruction, and that the
instructions do not improve, is a candidate for removal. The design is in
`~/.ai/ai/specs/2026-11-17-instruction-evals-design.md`.

## Files

- `evals.json` - probe tasks, prompts, and checks. Each check has `rule`: the line or line range in
  `instructions-agents.md` on 2026-11-17.
- `fixtures/*.sh` - one repo builder per eval. Each prints `base=<sha>`.
- `conditions.py` - the `CLAUDE.md` text of each condition.
- `run.py` - builds the repos, writes the condition text, runs `claude -p`, and grades.
- `grade.py` - the file, diff, tool order, commit, and judge check types. Writes `grading.json`.
- `report.py` - the table of removal candidates from a `none` and a `full` iteration.
- `canary.md` - a variant with one rule that is easy to see. The `canary` eval uses it to test
  the isolation.

The shared code, `compare.py`, and the fixture helpers are in `~/.config/agents/evals/`.

## Conditions

A condition is the `CLAUDE.md` text that a run gets:

| Condition | Text |
| --- | --- |
| `none` | No `CLAUDE.md` |
| `full` | `integrations/claude-code/CLAUDE.md`, with each `@<path>` import replaced by the file text |
| `variant:<path>` | The text of the file at `<path>` |

The run writes the text to `CLAUDE.md` in the root of the fixture repo, and adds it to
`.git/info/exclude`. It starts `claude -p` with `--setting-sources project,local`. With these
sources, Claude Code loads the project `CLAUDE.md` and no user-level files: no
`~/.claude/CLAUDE.md`, no user settings, no user plugins, no hooks, and output style `default`.

The `system/init` event has no field that lists the loaded `CLAUDE.md` files. `memory_paths` lists
only the auto memory dir. So the isolation check reads two other sources:

- The init event: `output_style` must be `default`, and the skill, plugin, MCP, and memory checks
  of `harness.isolation_problems` apply.
- The files: the check looks for `CLAUDE.md`, `CLAUDE.local.md`, `.claude/CLAUDE.md`, and
  `AGENTS.md` in the fixture repo and in each parent dir. A file that the condition did not write
  is an isolation problem.

The inline mods in `~/.claude/mods/` load also without the user source. The isolation settings of
`harness.py` turn them off like other plugins.

Other options:

- `--safe-mode` with `--append-system-prompt-file`: the text goes to the end of the system prompt,
  not to the place of a `CLAUDE.md`. The results are less exact.
- `--bare`: it reads only `ANTHROPIC_API_KEY`, not the subscription login.

## Run

`run.py` needs `claude -p` with `--permission-mode dontAsk` and an allowlist (`ALLOWED_TOOLS`).
Start it from your own shell, or with `!` in Claude Code. The default model is
`claude-opus-5-5`, with effort `medium`.

Make sure that the isolation works after a Claude Code update:

```sh
./run.py /tmp/canary --condition variant:$PWD/canary.md -n 1 canary  # 1/1
./run.py /tmp/canary --condition none -n 1 canary                     # 0/1
```

Each condition gets its own iteration dir, because `compare.py` merges all run dirs of one eval:

```text
~/.ai/ai/evals/instructions-workspace/
  iteration-1-none/eval-<name>/none/run-<k>/
  iteration-1-full/eval-<name>/full/run-<k>/
```

A run dir has these files:

- `ctx.json`, `transcript.jsonl`, `timing.json`, `grading.json`
- `after-tree/` - the working tree after the run
- `outputs/` - `final_reply.md`, `changes.diff` against the fixture base, and `commits.txt`
- `judge.json` - the cached answers of the judge

## Judge

A `judge` check asks a yes or no question about the run. Yes means that the rule holds. One
`claude-sonnet-5-5` call per run answers all judge questions of the eval. It reads the prompt,
`changes.diff`, and the final reply. The call runs with `--safe-mode`, so no `CLAUDE.md` or plugin
changes the answers. `judge.json` caches the answers. A grade asks the judge only the questions
with no answer in `judge.json`. After a change of a question, delete its answer in `judge.json`. A
failed call gives the evidence "no judge answer", and the next grade asks again.

## Phase 1

```sh
W=~/.ai/ai/evals/instructions-workspace
./run.py $W/iteration-1-none --condition none -n 5 -j 4
./run.py $W/iteration-1-full --condition full -n 5 -j 4
```

No job starts at 80% 5-hour or 50% 7-day subscription usage. After a guard stop, run the same
command again after the reset time. It runs only the runs that are missing or ended in an error.

## Report

```sh
./report.py $W/iteration-1-none $W/iteration-1-full
```

The report has one row per rule, with the passes under each condition and a verdict:

| Verdict | Meaning |
| --- | --- |
| `candidate` | `none` passes at least 90% of its graded results, and `full` passes no more often |
| `keep` | The instructions help, or `none` passes less than 90% |
| `insufficient` | A side has fewer than 3 graded results |

The report leaves out runs that ended in an error or were not isolated. Phase 2 removes all
candidates from a copy of `instructions-agents.md` and runs it as `variant:<path>`. Compare that
iteration with `iteration-1-full` in `compare.py`.
