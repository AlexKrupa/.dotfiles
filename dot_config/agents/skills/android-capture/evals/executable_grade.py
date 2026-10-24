#!/usr/bin/env python3
"""Grade android-capture eval runs against the checks in evals.json.

Usage: grade.py <iteration-dir>

Reads each <iteration-dir>/eval-<name>/<config>/run-<k>/ and writes grading.json there. A run dir
has: outputs/media/ (the captured files), outputs/final_reply.md, and transcript.jsonl.
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402

EVALS = HERE / "evals.json"


def run_check(check, run):
    """Return (passed, evidence)."""
    t = check["type"]
    names = [p.name for p in run["media"]]
    if t == "media_count":
        return len(names) == check["equals"], f"{len(names)} file(s): {names}"
    if t == "media_name_regex":
        bad = [n for n in names if not re.match(check["pattern"], n)]
        return bool(names) and not bad, f"files: {names}"
    raise ValueError(f"unknown check type {t}")


def load_run(run_dir):
    return {**harness.load_common(run_dir), "media": sorted((run_dir / "outputs" / "media").glob("*"))}


if __name__ == "__main__":
    harness.grade_main(__doc__, EVALS, load_run, run_check)
