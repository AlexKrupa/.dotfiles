#!/usr/bin/env python3
"""Run the review-branch evals with headless `claude -p`, then grade them.

Usage: run.py <iteration-dir> [-n RUNS] [-j JOBS] [--model MODEL] [--timeout SEC] [EVAL ...]

Runs every eval in evals.json except `slow` ones, or only the named evals. Each run gets its own
fixture repo in a temp dir and its own ~/.ai/rbe-<eval>-<k>/ report dir. After the run, the
report moves to <iteration-dir>/eval-<name>/with_skill/run-<k>/outputs/ and the report dir is
removed. The runs use the live skill at ~/.claude/skills/review-branch.
"""
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402
import grade  # noqa: E402

HOME = Path.home()
ALLOWED_TOOLS = "Bash Read Grep Glob Agent Skill Edit(~/.ai/**)"


def setup(ev, k, repos, run_dir):
    slug = f"rbe-{ev['name']}-{k}"
    if (HOME / ".ai" / slug).exists():
        sys.exit(f"{HOME / '.ai' / slug} exists from an earlier run. Check it, then remove it.")
    repo = repos / slug
    values = harness.run_fixture(HERE / ev["fixture"], repo)
    if "previous_report" in values:
        shutil.copy(values["previous_report"], run_dir / "previous-report.md")
    return {"repo": repo, "slug": slug, "prompt": harness.fill(ev["prompt"], values)}


def collect(ev, ctx, run_dir):
    reviews = HOME / ".ai" / ctx["slug"] / "reviews"
    if reviews.is_dir():
        for report in reviews.iterdir():
            shutil.move(report, run_dir / "outputs" / report.name)
        reviews.rmdir()
        reviews.parent.rmdir()


if __name__ == "__main__":
    harness.run_main(__doc__, HERE, "rbe-", ALLOWED_TOOLS, [HOME / ".ai", HOME / ".claude" / "skills"],
                     setup, collect, grade.grade_run)
