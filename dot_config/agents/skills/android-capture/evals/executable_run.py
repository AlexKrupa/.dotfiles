#!/usr/bin/env python3
"""Run the android-capture evals with headless `claude -p`, then grade them.

Each run gets its own notes-app repo in a temp dir. After the run, the ~/Downloads/android-* files
that the run wrote go to <run-dir>/outputs/media/. The runs use the live skill at
~/.claude/skills/android-capture and the connected emulator. Use -j 1.
"""
import json
import shutil
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402
import grade  # noqa: E402

HOME = Path.home()
DOWNLOADS = HOME / "Downloads"
# Edit rules also cover Write.
ALLOWED_TOOLS = ("Bash Read Grep Glob Skill Edit(//var/folders/**) Edit(//private/var/folders/**) "
                 "Edit(//tmp/**) Edit(//private/tmp/**) Edit(~/Downloads/**)")


def setup(ev, k, repos, run_dir):
    repo = repos / f"acp-{ev['name']}-{k}"
    harness.run_fixture(HERE / ev["fixture"], repo)
    ctx = {"repo": str(repo), "prompt": ev["prompt"], "start": time.time()}
    (run_dir / "ctx.json").write_text(json.dumps(ctx, indent=2))
    return ctx


def collect(ev, ctx, run_dir):
    out = run_dir / "outputs" / "media"
    out.mkdir(parents=True)
    for path in DOWNLOADS.glob("android-*"):
        if path.stat().st_mtime >= ctx["start"]:
            shutil.move(path, out / path.name)


if __name__ == "__main__":
    harness.run_main(__doc__, HERE, "acp-", ALLOWED_TOOLS,
                     [HOME / ".claude", HOME / ".config" / "agents", DOWNLOADS],
                     setup, collect, grade.load_run, grade.run_check)
