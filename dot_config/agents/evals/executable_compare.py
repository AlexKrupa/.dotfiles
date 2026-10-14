#!/usr/bin/env python3
"""Compare two graded iterations check by check, to find regressions.

Usage: compare.py <old-iteration-dir> <new-iteration-dir>

Prints the model and effort of each iteration, each check whose pass rate changed, the pass rate
per eval, and the mean tokens, time, and cost. A check that passed in more runs before than now is
a REGRESSION. With 3 runs per eval, a drop of one run can be noise. Rerun that eval before you act
on it.
"""
import json
import statistics
import sys
from pathlib import Path


def load(iteration):
    """Return {eval: {"checks": {text: [passed...]}, "timing": [timing...]}}.

    Leaves out runs that ended in an error (for example a usage limit), because their failed
    checks say nothing about the skill.
    """
    data = {}
    for grading in sorted(Path(iteration).glob("eval-*/*/run-*/grading.json")):
        run_dir = grading.parent
        timing_path = run_dir / "timing.json"
        timing = json.loads(timing_path.read_text()) if timing_path.exists() else {}
        if timing.get("is_error"):
            print(f"skipped {run_dir.relative_to(iteration)}: the run ended in an error")
            continue
        name = run_dir.parent.parent.name.removeprefix("eval-")
        entry = data.setdefault(name, {"checks": {}, "timing": []})
        for e in json.loads(grading.read_text())["expectations"]:
            entry["checks"].setdefault(e["text"], []).append(e["passed"])
        if timing:
            entry["timing"].append(timing)
    return data


def rate(results):
    return sum(results) / len(results) if results else None


def fmt(results):
    return f"{sum(results)}/{len(results)}" if results else "-"


def mean(timings, key):
    values = [t[key] for t in timings if t.get(key) is not None]
    return statistics.mean(values) if values else 0


def setup(data):
    """Return the model and effort pairs of the runs, for example `claude-opus-5-5/medium`."""
    pairs = {f"{t.get('model', 'unknown')}/{t.get('effort', 'unknown')}"
             for entry in data.values() for t in entry["timing"]}
    return ", ".join(sorted(pairs)) or "-"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    old, new = load(sys.argv[1]), load(sys.argv[2])
    print(f"model/effort: {setup(old)} -> {setup(new)}")
    regressions = 0
    for name in sorted(set(old) | set(new)):
        o, n = old.get(name, {"checks": {}, "timing": []}), new.get(name, {"checks": {}, "timing": []})
        all_o = [x for r in o["checks"].values() for x in r]
        all_n = [x for r in n["checks"].values() for x in r]
        print(f"\n{name}: {fmt(all_o)} -> {fmt(all_n)}"
              f"  tokens {mean(o['timing'], 'total_tokens'):.0f} -> {mean(n['timing'], 'total_tokens'):.0f}"
              f"  time {mean(o['timing'], 'total_duration_seconds'):.0f}s -> {mean(n['timing'], 'total_duration_seconds'):.0f}s"
              f"  cost ${mean(o['timing'], 'cost_usd'):.2f} -> ${mean(n['timing'], 'cost_usd'):.2f}")
        for text in sorted(set(o["checks"]) | set(n["checks"])):
            ro, rn = rate(o["checks"].get(text, [])), rate(n["checks"].get(text, []))
            if ro == rn:
                continue
            tag = "new check" if ro is None else "removed" if rn is None else "REGRESSION" if rn < ro else "better"
            regressions += tag == "REGRESSION"
            print(f"  {tag:10} {fmt(o['checks'].get(text, []))} -> {fmt(n['checks'].get(text, []))}  {text}")
    print(f"\n{regressions} regression(s)")
    sys.exit(1 if regressions else 0)


if __name__ == "__main__":
    main()
