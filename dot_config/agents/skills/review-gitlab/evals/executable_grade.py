#!/usr/bin/env python3
"""Grade review-gitlab eval runs against the checks in evals.json.

Usage: grade.py <iteration-dir>

Reads each <iteration-dir>/eval-<name>/<config>/run-<k>/ and writes grading.json there. A run dir
has: outputs/reviews/*.md (the review reports), outputs/git-state.txt, transcript.jsonl, and
repo-diff.txt. `reply_*` checks read the reply of the first turn in transcript.jsonl.
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
    if t in ("report_regex", "report_not_regex"):
        if not run["report"]:
            return False, "no report file"
        return harness.regex_check(check, run["report"], t == "report_regex", ignore_case=True)
    if t in ("state_regex", "state_not_regex"):
        return harness.regex_check(check, run["state"], t == "state_regex", ignore_case=True)
    raise ValueError(f"unknown check type {t}")


def first_reply(run_dir):
    """`claude -p` adds a turn when a background task stops. The skill reply is the first turn."""
    for event in harness.load_transcript(run_dir):
        if event.get("type") == "result":
            return event.get("result", "")
    return ""


def load_run(run_dir):
    state = run_dir / "outputs" / "git-state.txt"
    reports = sorted((run_dir / "outputs" / "reviews").glob("*.md"))
    return {
        **harness.load_common(run_dir),
        "reply": first_reply(run_dir),
        "report": "\n".join(p.read_text() for p in reports),
        "state": state.read_text() if state.exists() else "",
    }


if __name__ == "__main__":
    harness.grade_main(__doc__, EVALS, load_run, run_check)
