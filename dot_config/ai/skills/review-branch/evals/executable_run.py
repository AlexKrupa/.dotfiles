#!/usr/bin/env python3
"""Run the review-branch evals with headless `claude -p`, then grade them.

Usage: run.py <iteration-dir> [-n RUNS] [-j JOBS] [--model MODEL] [--timeout SEC] [EVAL ...]

Runs every eval in evals.json except `slow` ones, or only the named evals. Each run gets its own
fixture repo in a temp dir and its own ~/.ai/rbe-<eval>-<k>/ report dir. After the run, the
report moves to <iteration-dir>/eval-<name>/with_skill/run-<k>/outputs/ and the report dir is
removed. The runs use the live skill at ~/.claude/skills/review-branch.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
HOME = Path.home()
CONFIG = "with_skill"
ALLOWED_TOOLS = "Bash Read Grep Glob Agent Skill Edit(~/.ai/**)"


def sh(*args):
    p = subprocess.run(args, capture_output=True, text=True)
    if p.returncode:
        sys.exit(f"{' '.join(args)} failed with exit {p.returncode}:\n{p.stderr}")
    return p.stdout


def setup(ev, k, repos, run_dir):
    """Build the fixture repo. Return (repo, slug, prompt)."""
    slug = f"rbe-{ev['name']}-{k}"
    if (HOME / ".ai" / slug).exists():
        sys.exit(f"{HOME / '.ai' / slug} exists from an earlier run. Check it, then remove it.")
    repo = repos / slug
    (run_dir / "outputs").mkdir(parents=True, exist_ok=True)
    out = sh(str(HERE / ev["fixture"]), str(repo))
    values = dict(re.findall(r"^(\w+)=(.*)$", out, re.MULTILINE))
    if "previous_report" in values:
        shutil.copy(values["previous_report"], run_dir / "previous-report.md")
    (run_dir / "before.txt").write_text(sh(str(HERE / "snapshot.sh"), str(repo)))
    prompt = re.sub(r"\{(\w+)\}", lambda m: values[m.group(1)], ev["prompt"])
    return repo, slug, prompt


def run_claude(prompt, repo, run_dir, model, timeout):
    cmd = ["claude", "-p", prompt, "--output-format", "stream-json", "--verbose",
           "--permission-mode", "dontAsk", "--allowedTools", ALLOWED_TOOLS,
           "--add-dir", str(HOME / ".ai"), str(HOME / ".claude" / "skills"),
           "--no-session-persistence"]
    if model:
        cmd += ["--model", model]
    # CLAUDECODE blocks a nested session when this script runs from inside Claude Code.
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    start = time.time()
    with open(run_dir / "transcript.jsonl", "w") as out, open(run_dir / "stderr.txt", "w") as err:
        try:
            subprocess.run(cmd, cwd=repo, env=env, stdout=out, stderr=err, timeout=timeout)
        except subprocess.TimeoutExpired:
            err.write(f"\ntimeout after {timeout}s\n")
    return time.time() - start


def collect(repo, slug, run_dir, wall_seconds):
    result = {}
    for line in (run_dir / "transcript.jsonl").read_text().splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "result":
            result = event
    (run_dir / "outputs" / "final_reply.md").write_text(result.get("result", ""))
    usage = result.get("usage", {})
    tokens = sum(usage.get(k, 0) for k in ("input_tokens", "output_tokens",
                                           "cache_creation_input_tokens", "cache_read_input_tokens"))
    duration_ms = result.get("duration_ms", int(wall_seconds * 1000))
    (run_dir / "timing.json").write_text(json.dumps({
        "total_tokens": tokens,
        "duration_ms": duration_ms,
        "total_duration_seconds": round(duration_ms / 1000, 1),
        "cost_usd": result.get("total_cost_usd"),
        "num_turns": result.get("num_turns"),
        "is_error": result.get("is_error", True),
    }, indent=2))

    reviews = HOME / ".ai" / slug / "reviews"
    if reviews.is_dir():
        for report in reviews.iterdir():
            shutil.move(report, run_dir / "outputs" / report.name)
        reviews.rmdir()
        reviews.parent.rmdir()
    after = sh(str(HERE / "snapshot.sh"), str(repo))
    (run_dir / "after.txt").write_text(after)
    before = (run_dir / "before.txt").read_text()
    diff = subprocess.run(["diff", run_dir / "before.txt", run_dir / "after.txt"],
                          capture_output=True, text=True).stdout if before != after else ""
    (run_dir / "repo-diff.txt").write_text(diff)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("iteration_dir", type=Path)
    p.add_argument("evals", nargs="*", help="eval names (default: all except slow)")
    p.add_argument("-n", "--runs", type=int, default=3)
    p.add_argument("-j", "--jobs", type=int, default=4)
    p.add_argument("--model")
    p.add_argument("--timeout", type=int, default=900)
    args = p.parse_args()

    spec = json.loads((HERE / "evals.json").read_text())
    by_name = {ev["name"]: ev for ev in spec["evals"]}
    unknown = [n for n in args.evals if n not in by_name]
    if unknown:
        sys.exit(f"unknown eval(s): {unknown}. Known: {list(by_name)}")
    selected = [by_name[n] for n in args.evals] or [ev for ev in spec["evals"] if not ev.get("slow")]

    iteration = args.iteration_dir.resolve()
    repos = Path(tempfile.mkdtemp(prefix="rbe-"))
    sys.path.insert(0, str(HERE))
    import grade

    jobs = []
    for ev in selected:
        eval_dir = iteration / f"eval-{ev['name']}"
        eval_dir.mkdir(parents=True, exist_ok=True)
        (eval_dir / "eval_metadata.json").write_text(json.dumps({
            "eval_id": ev["id"], "eval_name": ev["name"], "prompt": ev["prompt"],
            "assertions": [c["text"] for c in grade.checks_for(spec, ev)],
        }, indent=2))
        for k in range(1, args.runs + 1):
            run_dir = eval_dir / CONFIG / f"run-{k}"
            if run_dir.exists():
                sys.exit(f"{run_dir} exists. Use a new iteration dir.")
            print(f"setup {ev['name']} run-{k}", flush=True)
            jobs.append((ev, k, run_dir, *setup(ev, k, repos, run_dir)))
    print(f"{len(jobs)} run(s), repos in {repos}", flush=True)

    def work(job):
        ev, k, run_dir, repo, slug, prompt = job
        seconds = run_claude(prompt, repo, run_dir, args.model, args.timeout)
        collect(repo, slug, run_dir, seconds)
        s = grade.grade_run(run_dir, grade.checks_for(spec, ev))["summary"]
        print(f"{ev['name']} run-{k}: {s['passed']}/{s['total']} in {seconds:.0f}s", flush=True)

    with ThreadPoolExecutor(args.jobs) as pool:
        list(pool.map(work, jobs))
    print(f"\nGrade again: {HERE / 'grade.py'} {iteration}")
    print(f"Compare:     {HERE / 'compare.py'} <previous-iteration-dir> {iteration}")


if __name__ == "__main__":
    main()
