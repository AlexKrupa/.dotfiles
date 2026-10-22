#!/usr/bin/env python3
"""Run the bump evals with headless `claude -p`, then grade them.

Each run gets its own fixture repo in a temp dir, and shims/glab answers the GitLab calls. After
the run, the glab calls go to <run-dir>/outputs/glab-calls.log and the branch state goes to
<run-dir>/outputs/git-state.txt. The runs use the live skill at ~/.claude/skills/bump.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402
import grade  # noqa: E402

HOME = Path.home()
ALLOWED_TOOLS = "Bash Read Grep Glob Skill Edit(//private/var/folders/**) Edit(//var/folders/**)"


def setup(ev, k, repos, run_dir):
    repo = repos / f"bump-{ev['name']}-{k}"
    harness.run_fixture(HERE / ev["fixture"], repo)
    ctx = {"repo": str(repo), "prompt": ev["prompt"]}
    (run_dir / "ctx.json").write_text(json.dumps(ctx, indent=2))
    return ctx


def git_state(repo):
    def git(*args):
        return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True).stdout

    lines = [f"current {git('branch', '--show-current').strip()}"]
    for branch in git("for-each-ref", "--format=%(refname:short)", "refs/heads").split():
        lines.append(f"commits {branch} {git('rev-list', '--count', f'main..{branch}').strip()}")
    return "\n".join(lines) + "\n"


def collect(ev, ctx, run_dir):
    calls = Path(ctx["repo"] + ".host") / "calls.log"
    out = run_dir / "outputs"
    if calls.exists():
        shutil.copy(calls, out / "glab-calls.log")
    (out / "git-state.txt").write_text(git_state(ctx["repo"]))


if __name__ == "__main__":
    os.environ["PATH"] = f"{HERE / 'shims'}:{os.environ['PATH']}"
    # Own watch daemon state: no run joins the real daemon. The eval daemon exits 60 seconds after
    # its last subscription ends.
    os.environ["XDG_STATE_HOME"] = tempfile.mkdtemp(prefix="watchd-")
    os.environ["WATCHD_IDLE_SECONDS"] = "60"
    harness.run_main(__doc__, HERE, "bump-", ALLOWED_TOOLS, [HOME / ".claude", HOME / ".config"],
                     setup, collect, grade.load_run, grade.run_check)
