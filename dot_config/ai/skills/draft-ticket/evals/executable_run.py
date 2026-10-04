#!/usr/bin/env python3
"""Run the draft-ticket evals with headless `claude -p`, then grade them.

Usage: run.py <iteration-dir> [-n RUNS] [-j JOBS] [--model MODEL] [--effort LEVEL] [--timeout SEC]
              [EVAL ...]

Each run gets its own fixture repo in a temp dir. The skill writes the ticket to
~/.ai/<repo-slug>/tickets/. After the run, the ticket files go to <run-dir>/outputs/tickets/ and
~/.ai/<repo-slug>/ is deleted. The runs use the live skill at ~/.claude/skills/draft-ticket.
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402
import grade  # noqa: E402

HOME = Path.home()
REPO_SLUG = HERE.parents[2] / "bin" / "repo-slug.sh"
# Edit rules also cover Write.
ALLOWED_TOOLS = "Bash Read Grep Glob Skill Edit(~/.ai/**)"


def setup(ev, k, repos, run_dir):
    repo = repos / f"dtk-{ev['name']}-{k}"
    values = harness.run_fixture(HERE / ev["fixture"], repo)
    slug = subprocess.run([str(REPO_SLUG)], cwd=repo, capture_output=True, text=True).stdout.strip()
    ctx = {"repo": str(repo), "prompt": harness.fill(ev["prompt"], values), "slug": slug}
    (run_dir / "ctx.json").write_text(json.dumps(ctx, indent=2))
    return ctx


def collect(ev, ctx, run_dir):
    work_dir = HOME / ".ai" / ctx["slug"]
    out = run_dir / "outputs" / "tickets"
    out.mkdir()
    for ticket in (work_dir / "tickets").glob("*.md"):
        shutil.copy(ticket, out)
    shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    harness.run_main(__doc__, HERE, "dtk-", ALLOWED_TOOLS,
                     [HOME / ".claude", HOME / ".config" / "ai", HOME / ".ai"],
                     setup, collect, grade.grade_run)
