#!/usr/bin/env python3
"""Run the instruction evals with headless `claude -p` under one condition, then grade them.

Usage: run.py <iteration-dir> --condition none|full|variant:<path> [harness flags] [EVAL ...]

Each run gets its own fixture repo in a temp dir. The condition text goes to `CLAUDE.md` in the
repo root, excluded from git, and the run loads only the project and local setting sources. See
README.md, section "Conditions". The runs go to <iteration-dir>/eval-<name>/<condition>/run-<k>/.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import harness  # noqa: E402
import conditions  # noqa: E402
import grade  # noqa: E402

# Edit rules also cover Write. The fixture repos are in temp dirs.
ALLOWED_TOOLS = ("Bash Read Grep Glob Edit(//var/folders/**) Edit(//private/var/folders/**) "
                 "Edit(//tmp/**) Edit(//private/tmp/**)")
SETTING_SOURCES = ["--setting-sources", "project,local"]
INSTRUCTION_FILES = ["CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md", "AGENTS.md"]
# The fixture repos turn off the global 1Password signing, but `git diff` must not use it either.
GIT_ENV = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                          env=GIT_ENV, check=True).stdout


def make_setup(condition):
    text = conditions.text(condition)

    def setup(ev, k, repos, run_dir):
        repo = repos / f"ins-{ev['name']}-{k}"
        values = harness.run_fixture(HERE / ev["fixture"], repo)
        # The instructions and the test caches are not part of the task, so git and the repo
        # checks do not see them.
        with open(repo / ".git" / "info" / "exclude", "a") as exclude:
            exclude.write("/CLAUDE.md\n__pycache__/\n")
        if text:
            (repo / "CLAUDE.md").write_text(text)
        ctx = {"repo": str(repo), "prompt": harness.fill(ev["prompt"], values), "eval": ev["name"],
               "condition": condition, "base": values["base"], "claude_md": bool(text)}
        (run_dir / "ctx.json").write_text(json.dumps(ctx, indent=2))
        return ctx

    return setup


def instruction_files(repo, claude_md):
    """Return the instruction files that Claude Code can load in `repo` and that the condition did
    not write."""
    found = []
    for directory in [repo, *repo.parents]:
        for name in INSTRUCTION_FILES:
            path = directory / name
            if path.exists() and not (claude_md and path == repo / "CLAUDE.md"):
                found.append(str(path))
    return found


def init_event(run_dir):
    return next((e for e in harness.load_transcript(run_dir)
                 if e.get("type") == "system" and e.get("subtype") == "init"), None)


def collect(ev, ctx, run_dir):
    repo, out = Path(ctx["repo"]), run_dir / "outputs"
    git(repo, "add", "-A", "-N")
    (out / "changes.diff").write_text(git(repo, "diff", "--no-ext-diff", ctx["base"]))
    (out / "commits.txt").write_text(git(repo, "log", "--format=%h %s", f"{ctx['base']}..HEAD"))
    # A copy, so that a regrade works after the temp dir is gone.
    shutil.copytree(repo, run_dir / "after-tree", symlinks=True,
                    ignore=shutil.ignore_patterns(".git", "__pycache__"))

    problems = instruction_files(repo, ctx["claude_md"])
    init = init_event(run_dir)
    if init and init.get("output_style") != "default":
        problems.append(f"output style {init.get('output_style')}")
    if problems:
        timing_path = run_dir / "timing.json"
        timing = json.loads(timing_path.read_text())
        timing["isolation_problems"] += problems
        timing_path.write_text(json.dumps(timing, indent=2))


def main():
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--condition", required=True)
    # The full model ID, so that an alias change does not mix results.
    p.add_argument("--model", default="claude-opus-5-5")
    args, rest = p.parse_known_args()
    sys.argv = [sys.argv[0], *rest, "--model", args.model]
    harness.run_main(__doc__, HERE, "ins-", ALLOWED_TOOLS, [Path(tempfile.gettempdir())],
                     make_setup(args.condition), collect, grade.load_run, grade.run_check,
                     extra_settings={"outputStyle": "default"},
                     condition_args=lambda ev, ctx: SETTING_SOURCES,
                     config=conditions.config_name(args.condition))


if __name__ == "__main__":
    main()
