#!/usr/bin/env python3
"""Grade draft-pr eval runs against the checks in evals.json.

Usage: grade.py <iteration-dir>

Reads each <iteration-dir>/eval-<name>/<config>/run-<k>/ and writes grading.json there. A run dir
has: outputs/prs/*.md (the PR files), outputs/git-state.txt, outputs/branch-log.txt,
outputs/final_reply.md, transcript.jsonl, and repo-diff.txt. `reply_*` checks read the reply of
the first turn in transcript.jsonl.
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402

EVALS = HERE / "evals.json"
FRONTMATTER = re.compile(r"\A---\n.*?\n---\n", re.DOTALL)


def run_check(check, run):
    """Return (passed, evidence)."""
    t = check["type"]
    if t in ("state_regex", "state_not_regex"):
        return regex(check, run["state"], t == "state_regex")
    if t in ("log_regex", "log_not_regex"):
        return regex(check, run["log"], t == "log_regex")
    prs = run["prs"]
    if t == "pr_count":
        return len(prs) == check["equals"], f"{len(prs)} file(s): {[p.name for p in prs]}"
    if not prs:
        return False, "no PR file"
    if t == "pr_name":
        bad = [p.name for p in prs if not re.match(check["pattern"], p.name)]
        return not bad, "ok" if not bad else f"bad name(s): {bad}"
    text = "\n".join(p.read_text() for p in prs)
    if t in ("pr_regex", "pr_not_regex"):
        return regex(check, text, t == "pr_regex")
    if t in ("pr_body_regex", "pr_body_not_regex"):
        return regex(check, FRONTMATTER.sub("", text, count=1), t == "pr_body_regex")
    raise ValueError(f"unknown check type {t}")


def regex(check, text, positive):
    return harness.regex_check(check, text, positive, ignore_case=True)


def first_reply(run_dir):
    """`claude -p` adds a turn when a background task stops. The skill reply is the first turn."""
    for event in harness.load_transcript(run_dir):
        if event.get("type") == "result":
            return event.get("result", "")
    return ""


def load_run(run_dir):
    state = run_dir / "outputs" / "git-state.txt"
    log = run_dir / "outputs" / "branch-log.txt"
    return {
        **harness.load_common(run_dir),
        "reply": first_reply(run_dir),
        "prs": sorted((run_dir / "outputs" / "prs").glob("*.md")),
        "state": state.read_text() if state.exists() else "",
        "log": log.read_text() if log.exists() else "",
    }


if __name__ == "__main__":
    harness.grade_main(__doc__, EVALS, load_run, run_check)
