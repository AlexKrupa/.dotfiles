#!/usr/bin/env python3
"""Run the draft-pr evals with headless `claude -p`, then grade them.

Each run gets its own fixture repo in a temp dir. The skill writes the PR file to
~/.ai/<repo-slug>/prs/. After the run, the PR files go to <run-dir>/outputs/prs/, the branch state
goes to <run-dir>/outputs/git-state.txt, and ~/.ai/<repo-slug>/ is deleted. The runs use the live
skill at ~/.claude/skills/draft-pr.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402
import grade  # noqa: E402

HOME = Path.home()
SHIMS = HERE / "shims"
# Edit rules also cover Write. The watch evals fix code in the fixture repos in the temp dir.
ALLOWED_TOOLS = "Bash ToolSearch Monitor TaskStop Read Grep Glob Skill Edit(~/.ai/**) Edit(//private/var/folders/**) Edit(//var/folders/**)"


def setup(ev, k, repos, run_dir):
    return harness.setup_with_slug(HERE / ev["fixture"], repos / f"dpr-{ev['name']}-{k}",
                                   ev["prompt"], run_dir)


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
    harness.collect_work_dir(ctx, run_dir, "prs")
    (run_dir / "outputs" / "git-state.txt").write_text(git_state(ctx["repo"]))
    (run_dir / "outputs" / "branch-log.txt").write_text(subprocess.run(
        ["git", "-C", ctx["repo"], "log", "-p", "--format=commit %s", "main..tags-in-list"],
        capture_output=True, text=True).stdout)


if __name__ == "__main__":
    # The watch evals need the git-spice shim. For all other commands, it runs the real git-spice.
    os.environ["PATH"] = f"{SHIMS}:{os.environ['PATH']}"
    # Own watch daemon state: no run joins the real daemon. The eval daemon exits 60 seconds after
    # its last subscription ends.
    os.environ["XDG_STATE_HOME"] = tempfile.mkdtemp(prefix="watchd-")
    os.environ["WATCHD_IDLE_SECONDS"] = "60"
    harness.run_main(__doc__, HERE, "dpr-", ALLOWED_TOOLS,
                     [HOME / ".claude", HOME / ".config" / "agents", HOME / ".ai"],
                     setup, collect, grade.load_run, grade.run_check)
