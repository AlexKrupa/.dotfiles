#!/usr/bin/env python3
"""Run the draft-pr evals with headless `claude -p`, then grade them.

Usage: run.py <iteration-dir> [-n RUNS] [-j JOBS] [--model MODEL] [--effort LEVEL] [--timeout SEC]
              [EVAL ...]

Each run gets its own fixture repo in a temp dir. The skill writes the PR file to
~/.ai/<repo-slug>/prs/. After the run, the PR files go to <run-dir>/outputs/prs/, the branch state
goes to <run-dir>/outputs/git-state.txt, and ~/.ai/<repo-slug>/ is deleted. The runs use the live
skill at ~/.claude/skills/draft-pr.
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
    repo = repos / f"dpr-{ev['name']}-{k}"
    values = harness.run_fixture(HERE / ev["fixture"], repo)
    slug = subprocess.run([str(REPO_SLUG)], cwd=repo, capture_output=True, text=True).stdout.strip()
    ctx = {"repo": str(repo), "prompt": harness.fill(ev["prompt"], values), "slug": slug}
    (run_dir / "ctx.json").write_text(json.dumps(ctx, indent=2))
    return ctx


def git_state(repo):
    """The subject of the main tip, then for each other branch: its name, its subjects in
    main..<branch>, and the refs it contains."""
    def git(*args):
        return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)

    refs = git("for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes").stdout.split()
    lines = [f"main-head {git('log', '-1', '--format=%s', 'main').stdout.strip()}"]
    for branch in git("for-each-ref", "--format=%(refname:short)", "refs/heads").stdout.split():
        if branch == "main":
            continue
        lines.append(f"branch {branch}")
        lines += [f"subject {s}" for s in git("log", "--format=%s", f"main..{branch}").stdout.splitlines()]
        ancestors = [r for r in refs
                     if r != branch and git("merge-base", "--is-ancestor", r, branch).returncode == 0]
        lines.append("ancestors " + " ".join(ancestors))
    return "\n".join(lines) + "\n"


def collect(ev, ctx, run_dir):
    work_dir = HOME / ".ai" / ctx["slug"]
    out = run_dir / "outputs" / "prs"
    out.mkdir()
    for pr in (work_dir / "prs").glob("*.md"):
        shutil.copy(pr, out)
    (run_dir / "outputs" / "git-state.txt").write_text(git_state(ctx["repo"]))
    shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    harness.run_main(__doc__, HERE, "dpr-", ALLOWED_TOOLS,
                     [HOME / ".claude", HOME / ".config" / "ai", HOME / ".ai"],
                     setup, collect, grade.grade_run)
