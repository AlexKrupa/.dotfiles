#!/usr/bin/env python3
"""Run the deslop evals with headless `claude -p`, then grade them.

Usage: run.py <iteration-dir> [-n RUNS] [-j JOBS] [--model MODEL] [--timeout SEC] [EVAL ...]

Each run gets its own fixture repo in a temp dir. After the run, a clone of the repo gets
`git rebase -i --autosquash <base>` in <run-dir>/applied/, so the checks read the history that the
user gets after the fixups. An eval with `"output": "worktree"` gets a copy of the repo with its
working tree in applied/ instead, and no rebase. The runs use the live skill at
~/.claude/skills/deslop.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402
import grade  # noqa: E402

HOME = Path.home()
# Edit rules also cover Write. The fixture repos and the skill's message files are in temp dirs.
ALLOWED_TOOLS = ("Bash Read Grep Glob Skill Edit(//var/folders/**) Edit(//private/var/folders/**) "
                 "Edit(//tmp/**) Edit(//private/tmp/**)")
LOG = "--format=%h %s%n%b"
# The rebase runs without the user's global config: no signing, no editor, no external diff.
GIT_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
           "GIT_SEQUENCE_EDITOR": "true", "GIT_EDITOR": "true",
           "GIT_AUTHOR_NAME": "Test Dev", "GIT_AUTHOR_EMAIL": "dev@example.com",
           "GIT_COMMITTER_NAME": "Test Dev", "GIT_COMMITTER_EMAIL": "dev@example.com"}


def git(repo, *args, check=True):
    p = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, env=GIT_ENV)
    if check and p.returncode:
        sys.exit(f"git {' '.join(args)} in {repo} failed:\n{p.stderr}")
    return p


def setup(ev, k, repos, run_dir):
    repo = repos / f"dse-{ev['name']}-{k}"
    values = harness.run_fixture(HERE / ev["fixture"], repo)
    ctx = {"repo": str(repo), "prompt": harness.fill(ev["prompt"], values),
           "base": values.get("base"), "head": git(repo, "rev-parse", "HEAD").stdout.strip(),
           "index": git(repo, "diff", "--no-ext-diff", "--cached").stdout}
    (run_dir / "ctx.json").write_text(json.dumps(ctx, indent=2))
    # Checks with `"ref": "before"` read the working tree from before the run.
    shutil.copytree(repo, run_dir / "before-tree", symlinks=True, ignore=shutil.ignore_patterns(".git"))
    return ctx


def collect(ev, ctx, run_dir):
    repo, out, base, head = ctx["repo"], run_dir / "outputs", ctx["base"], ctx["head"]
    if not base:
        return
    (out / "status.txt").write_text(git(repo, "status", "--porcelain").stdout)
    (out / "new-commits.txt").write_text(git(repo, "log", LOG, f"{head}..HEAD").stdout)
    (out / "fixups.diff").write_text(git(repo, "diff", "--no-ext-diff", head).stdout)
    (out / "index.txt").write_text(git(repo, "diff", "--no-ext-diff", "--cached").stdout)

    if ev.get("output") == "worktree":
        # The fsmonitor daemon socket in .git cannot be copied.
        shutil.copytree(repo, run_dir / "applied", symlinks=True,
                        ignore=shutil.ignore_patterns("fsmonitor--daemon.ipc"))
        return

    applied = run_dir / "applied"
    git(run_dir, "clone", "-q", repo, "applied")
    p = git(applied, "rebase", "-i", "--autosquash", base, check=False)
    (run_dir / "rebase.txt").write_text(f"rc={p.returncode}\n{p.stdout}{p.stderr}")
    if p.returncode:
        git(applied, "rebase", "--abort", check=False)
    (out / "applied-log.txt").write_text(git(applied, "log", LOG, f"{base}..HEAD").stdout)
    (out / "applied.diff").write_text(git(applied, "diff", "--no-ext-diff", head, "HEAD").stdout)


if __name__ == "__main__":
    harness.run_main(__doc__, HERE, "dse-", ALLOWED_TOOLS, [HOME / ".claude", HOME / ".config" / "ai"],
                     setup, collect, grade.grade_run)
