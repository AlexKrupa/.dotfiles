#!/usr/bin/env python3
"""Grade draft-ticket eval runs against the checks in evals.json.

Usage: grade.py <iteration-dir>

Reads each <iteration-dir>/eval-<name>/<config>/run-<k>/ and writes grading.json there. A run dir
has: outputs/tickets/*.md (the ticket files), outputs/final_reply.md, transcript.jsonl,
repo-diff.txt, and ctx.json. `repo_*` checks run `cmd` in the fixture repo and match its output.
A `patterns` value that starts with `@` names a list in `pattern_sets`.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402

EVALS = HERE / "evals.json"


def run_check(check, run):
    """Return (passed, evidence)."""
    common = harness.common_check(check, run)
    if common is not None:
        return common
    t = check["type"]
    tickets = run["tickets"]
    if t in ("repo_regex", "repo_not_regex"):
        p = subprocess.run(check["cmd"], shell=True, cwd=run["repo"], capture_output=True, text=True)
        return regex(check, p.stdout + p.stderr, t == "repo_regex")
    if t == "ticket_count":
        return len(tickets) == check["equals"], f"{len(tickets)} file(s): {[p.name for p in tickets]}"
    if not tickets:
        return False, "no ticket file"
    if t == "ticket_name":
        bad = [p.name for p in tickets if not re.match(check["pattern"], p.name)]
        return not bad, "ok" if not bad else f"bad name(s): {bad}"
    if t in ("ticket_regex", "ticket_not_regex"):
        text = "\n".join(p.read_text() for p in tickets)
        return regex(check, text, t == "ticket_regex")
    raise ValueError(f"unknown check type {t}")


def regex(check, text, positive):
    """Like harness.regex_check, but case-insensitive unless the check sets `case`."""
    flags = re.MULTILINE if check.get("case") else harness.FLAGS
    hit = [p for p in check["patterns"] if re.search(p, text, flags)]
    if positive:
        missing = [p for p in check["patterns"] if p not in hit]
        return not missing, "all patterns match" if not missing else f"missing: {missing}"
    found = [re.search(p, text, flags).group(0) for p in hit]
    return not hit, "no pattern matches" if not hit else f"matched: {found}"


def load_run(run_dir):
    return {
        **harness.load_common(run_dir),
        "tickets": sorted((run_dir / "outputs" / "tickets").glob("*.md")),
        "repo": json.loads((run_dir / "ctx.json").read_text())["repo"],
    }


def expand(checks):
    sets = json.loads(EVALS.read_text()).get("pattern_sets", {})
    out = []
    for c in checks:
        if isinstance(c.get("patterns"), str) and c["patterns"].startswith("@"):
            c = {**c, "patterns": sets[c["patterns"][1:]]}
        out.append(c)
    return out


def grade_run(run_dir, checks):
    return harness.grade_run(run_dir, expand(checks), load_run, run_check)


if __name__ == "__main__":
    harness.grade_main(__doc__, EVALS, grade_run)
