#!/usr/bin/env python3
"""Print the removal candidates of instructions-agents.md from two graded iterations.

Usage: report.py <none-iteration-dir> <full-iteration-dir>

Prints one Markdown table row per rule: the rule, the count of checks of the rule, the passes
under `none` and under `full`, and the verdict:

- `candidate`: `none` passes at least 90% of its graded runs, and `full` passes no more often.
- `keep`: else.
- `insufficient`: a side has fewer than 3 graded check results.

A check with `"rule": "L115,L170"` counts for each rule. Runs that ended in an error or were not
isolated are left out, like in compare.py.
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import compare  # noqa: E402
import harness  # noqa: E402

MIN_RUNS = 3
CANDIDATE_RATE = 0.9


def verdict(none, full):
    if len(none) < MIN_RUNS or len(full) < MIN_RUNS:
        return "insufficient"
    none_rate, full_rate = sum(none) / len(none), sum(full) / len(full)
    if none_rate >= CANDIDATE_RATE and full_rate <= none_rate:
        return "candidate"
    return "keep"


def rules_of_checks(spec):
    """Return {(eval name, check text): [rule, ...]} for the checks that have a rule."""
    return {(ev["name"], check["text"]): check["rule"].split(",")
            for ev in spec["evals"] for check in harness.checks_for(spec, ev) if check.get("rule")}


def results_by_rule(data, rules):
    by_rule = {}
    for name, entry in data.items():
        for text, results in entry["checks"].items():
            for rule in rules.get((name, text), []):
                by_rule.setdefault(rule, []).extend(results)
    return by_rule


def rows(spec, none_dir, full_dir):
    rules = rules_of_checks(spec)
    none = results_by_rule(compare.load(none_dir), rules)
    full = results_by_rule(compare.load(full_dir), rules)
    check_counts = {}
    for rule_list in rules.values():
        for rule in rule_list:
            check_counts[rule] = check_counts.get(rule, 0) + 1
    names = sorted(set(none) | set(full), key=lambda rule: int(re.search(r"\d+", rule).group()))
    return [{"rule": rule, "checks": check_counts[rule], "none": none.get(rule, []),
             "full": full.get(rule, []), "verdict": verdict(none.get(rule, []), full.get(rule, []))}
            for rule in names]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    none_dir, full_dir = Path(sys.argv[1]), Path(sys.argv[2])
    spec = json.loads((HERE / "evals.json").read_text())
    for label, path in (("none", none_dir), ("full", full_dir)):
        data = compare.load(path)
        run_count = len(list(path.glob("eval-*/*/run-*/grading.json")))
        print(f"{label}: {path}, {run_count} graded run(s), {compare.setup(data)}, "
              f"instructions_sha {compare.instructions(data)}")
    print("\n| Rule | Checks | none | full | Verdict |\n| --- | --- | --- | --- | --- |")
    for row in rows(spec, none_dir, full_dir):
        print(f"| {row['rule']} | {row['checks']} | {compare.fmt(row['none'])} | "
              f"{compare.fmt(row['full'])} | {row['verdict']} |")


if __name__ == "__main__":
    main()
