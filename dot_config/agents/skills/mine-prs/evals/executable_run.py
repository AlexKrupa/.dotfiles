#!/usr/bin/env python3
"""Run the mine-prs evals with headless `claude -p`, then grade them.

Each run gets its own fixture repo in a temp dir, and shims/glab answers the GitLab calls. After
the run, the glab calls go to <run-dir>/outputs/glab-calls.log and the findings files go to
<run-dir>/outputs/mined/. The runs use the live skill at ~/.claude/skills/mine-prs.
"""
import json
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402
import grade  # noqa: E402

HOME = Path.home()
ALLOWED_TOOLS = "Bash Read Grep Glob Skill Write(~/.ai/**) Edit(~/.ai/**)"


def setup(ev, k, repos, run_dir):
    repo = repos / f"mine-prs-{ev['name']}-{k}"
    return harness.setup_with_slug(HERE / ev["fixture"], repo, ev["prompt"], run_dir)


def collect(ev, ctx, run_dir):
    calls = Path(ctx["repo"] + ".host") / "calls.log"
    if calls.exists():
        shutil.copy(calls, run_dir / "outputs" / "glab-calls.log")
    harness.collect_work_dir(ctx, run_dir, "mined")


if __name__ == "__main__":
    os.environ["PATH"] = f"{HERE / 'shims'}:{os.environ['PATH']}"
    harness.run_main(__doc__, HERE, "mine-prs-", ALLOWED_TOOLS,
                     [HOME / ".claude", HOME / ".config", HOME / ".ai"],
                     setup, collect, grade.load_run, grade.run_check)
