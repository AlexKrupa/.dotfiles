#!/usr/bin/env python3
"""Run the review-pr evals with headless `claude -p`, then grade them.

Each run gets its own fixture repo in a temp dir, with a review report under
~/.ai/<repo-slug>/reviews/. After the run, the reports go to <run-dir>/outputs/reviews/, the
branch state goes to <run-dir>/outputs/git-state.txt, and ~/.ai/<repo-slug>/ is deleted. The runs
use the live skill at ~/.claude/skills/review-pr.
"""
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402
import grade  # noqa: E402

HOME = Path.home()
SHIMS = HERE / "shims"
# Edit rules also cover Write. The skill adds an update to the report in ~/.ai/.
ALLOWED_TOOLS = "Bash Read Grep Glob Skill Edit(~/.ai/**)"


def setup(ev, k, repos, run_dir):
    return harness.setup_with_slug(HERE / ev["fixture"], repos / f"rgl-{ev['name']}-{k}",
                                   ev["prompt"], run_dir)


def git_state(repo):
    """The current branch, if the MR branch moved from the reviewed commit, and the status."""
    def git(*args):
        return subprocess.run(["git", "-C", repo, *args], capture_output=True,
                              text=True).stdout.strip()

    moved = "no" if git("rev-parse", "tags-model") == git("rev-parse", "refs/eval/reviewed") else "yes"
    status = git("status", "--porcelain").replace("\n", " | ")
    return f"head {git('branch', '--show-current')}\nbranch-moved {moved}\nstatus {status}\n"


def collect(ev, ctx, run_dir):
    harness.collect_work_dir(ctx, run_dir, "reviews")
    (run_dir / "outputs" / "git-state.txt").write_text(git_state(ctx["repo"]))


if __name__ == "__main__":
    # The glab shim stops each watch at its first GitLab call.
    os.environ["PATH"] = f"{SHIMS}:{os.environ['PATH']}"
    harness.run_main(__doc__, HERE, "rgl-", ALLOWED_TOOLS,
                     [HOME / ".claude", HOME / ".config" / "ai", HOME / ".ai"],
                     setup, collect, grade.load_run, grade.run_check)
