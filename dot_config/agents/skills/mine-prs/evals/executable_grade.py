#!/usr/bin/env python3
"""Grade mine-prs eval runs against the checks in evals.json.

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
    if t in ("findings_regex", "findings_not_regex"):
        return harness.regex_check(check, run["findings"], t == "findings_regex")
    if t in ("calls_regex", "calls_not_regex"):
        return harness.regex_check(check, run["calls"], t == "calls_regex")
    raise ValueError(f"unknown check type {t}")


def read(path):
    return path.read_text() if path.exists() else ""


def load_run(run_dir):
    out = run_dir / "outputs"
    findings = "\n".join(p.read_text() for p in sorted((out / "mined").glob("*-prs*.md")))
    return {**harness.load_common(run_dir), "findings": findings,
            "calls": read(out / "glab-calls.log")}


if __name__ == "__main__":
    harness.grade_main(__doc__, EVALS, load_run, run_check)
