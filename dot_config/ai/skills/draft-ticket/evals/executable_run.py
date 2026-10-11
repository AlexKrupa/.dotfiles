#!/usr/bin/env python3
"""Run the draft-ticket evals with headless `claude -p`, then grade them.

Each run gets its own fixture repo in a temp dir. The skill writes the ticket to
~/.ai/<repo-slug>/tickets/. After the run, the ticket files go to <run-dir>/outputs/tickets/ and
~/.ai/<repo-slug>/ is deleted. The runs use the live skill at ~/.claude/skills/draft-ticket.
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402
import grade  # noqa: E402

HOME = Path.home()
# Edit rules also cover Write.
ALLOWED_TOOLS = "Bash Read Grep Glob Skill Edit(~/.ai/**)"


def setup(ev, k, repos, run_dir):
    return harness.setup_with_slug(HERE / ev["fixture"], repos / f"dtk-{ev['name']}-{k}",
                                   ev["prompt"], run_dir)


def collect(ev, ctx, run_dir):
    harness.collect_work_dir(ctx, run_dir, "tickets")


if __name__ == "__main__":
    harness.run_main(__doc__, HERE, "dtk-", ALLOWED_TOOLS,
                     [HOME / ".claude", HOME / ".config" / "ai", HOME / ".ai"],
                     setup, collect, grade.load_run, grade.run_check)
