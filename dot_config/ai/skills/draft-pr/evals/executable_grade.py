#!/usr/bin/env python3
"""Grade draft-pr eval runs against the checks in evals.json.

Usage: grade.py <iteration-dir>

Reads each <iteration-dir>/eval-<name>/<config>/run-<k>/ and writes grading.json there. A run dir
has: outputs/prs/*.md (the PR files), outputs/git-state.txt, outputs/final_reply.md,
transcript.jsonl, and repo-diff.txt. A `patterns` value that starts with `@` names a list in
`pattern_sets`.
"""
import json
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
    common = harness.common_check(check, run)
    if common is not None:
        return common
    t = check["type"]
    if t in ("state_regex", "state_not_regex"):
        return regex(check, run["state"], t == "state_regex")
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
    """Like harness.regex_check, but case-insensitive unless the check sets `case`."""
    flags = re.MULTILINE if check.get("case") else harness.FLAGS
    hit = [p for p in check["patterns"] if re.search(p, text, flags)]
    if positive:
        missing = [p for p in check["patterns"] if p not in hit]
        return not missing, "all patterns match" if not missing else f"missing: {missing}"
    found = [re.search(p, text, flags).group(0) for p in hit]
    return not hit, "no pattern matches" if not hit else f"matched: {found}"


def load_run(run_dir):
    state = run_dir / "outputs" / "git-state.txt"
    return {
        **harness.load_common(run_dir),
        "prs": sorted((run_dir / "outputs" / "prs").glob("*.md")),
        "state": state.read_text() if state.exists() else "",
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
