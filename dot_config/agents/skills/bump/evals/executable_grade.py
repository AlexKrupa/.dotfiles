#!/usr/bin/env python3
"""Grade bump eval runs against the checks in evals.json.

Usage: grade.py <iteration-dir>

Reads each <iteration-dir>/eval-<name>/<config>/run-<k>/ and writes grading.json there.
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402

EVALS = HERE / "evals.json"


def run_check(check, run):
    """Return (passed, evidence)."""
    t = check["type"]
    if t in ("state_regex", "state_not_regex"):
        return harness.regex_check(check, run["state"], t == "state_regex", ignore_case=True)
    if t in ("calls_regex", "calls_not_regex"):
        return harness.regex_check(check, run["calls"], t == "calls_regex", ignore_case=True)
    raise ValueError(f"unknown check type {t}")


def read(path):
    return path.read_text() if path.exists() else ""


def load_run(run_dir):
    out = run_dir / "outputs"
    return {**harness.load_common(run_dir),
            "state": read(out / "git-state.txt"), "calls": read(out / "glab-calls.log")}


if __name__ == "__main__":
    harness.grade_main(__doc__, EVALS, load_run, run_check)
