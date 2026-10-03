"""Shared code for skill evals: run headless `claude -p`, record timing, and grade the runs.

A skill's `evals/` dir has its own `run.py` and `grade.py`. They import this module and add the
fixture setup, the output collection, and the check types that only that skill needs.

Layout of an iteration dir: <iteration>/eval-<name>/with_skill/run-<k>/ with `outputs/`,
`transcript.jsonl`, `timing.json`, `before.txt`, `after.txt`, `repo-diff.txt`, and
`grading.json`. skill-creator's aggregate_benchmark and eval viewer read this layout.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
HOME = Path.home()
CONFIG = "with_skill"
FLAGS = re.IGNORECASE | re.MULTILINE


def sh(*args, cwd=None):
    p = subprocess.run(args, capture_output=True, text=True, cwd=cwd)
    if p.returncode:
        sys.exit(f"{' '.join(map(str, args))} failed with exit {p.returncode}:\n{p.stderr}")
    return p.stdout


def run_fixture(fixture, repo):
    """Build the fixture repo. Return the `key=value` lines that the fixture prints."""
    return dict(re.findall(r"^(\w+)=(.*)$", sh(str(fixture), str(repo)), re.MULTILINE))


def fill(prompt, values):
    return re.sub(r"\{(\w+)\}", lambda m: values[m.group(1)], prompt)


def run_claude(prompt, cwd, run_dir, allowed_tools, add_dirs, model, timeout):
    cmd = ["claude", "-p", prompt, "--output-format", "stream-json", "--verbose",
           "--permission-mode", "dontAsk", "--allowedTools", allowed_tools,
           "--add-dir", *map(str, add_dirs), "--no-session-persistence"]
    if model:
        cmd += ["--model", model]
    # CLAUDECODE blocks a nested session when the runner starts from inside Claude Code.
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    start = time.time()
    with open(run_dir / "transcript.jsonl", "w") as out, open(run_dir / "stderr.txt", "w") as err:
        try:
            subprocess.run(cmd, cwd=cwd, env=env, stdout=out, stderr=err, timeout=timeout)
        except subprocess.TimeoutExpired:
            err.write(f"\ntimeout after {timeout}s\n")
    return time.time() - start


def collect_result(run_dir, wall_seconds):
    """Write outputs/final_reply.md and timing.json from the transcript's result event."""
    result = {}
    for event in load_transcript(run_dir):
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


def snapshot(repo, run_dir, name):
    (run_dir / name).write_text(sh(str(HERE / "snapshot.sh"), str(repo)))


def write_repo_diff(run_dir):
    before, after = run_dir / "before.txt", run_dir / "after.txt"
    diff = subprocess.run(["diff", before, after], capture_output=True, text=True).stdout
    (run_dir / "repo-diff.txt").write_text(diff)


def load_transcript(run_dir):
    events = []
    path = run_dir / "transcript.jsonl"
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return events


def tool_uses(transcript):
    """Yield (name, input, is_subagent, message_index) for each tool call in the transcript."""
    for i, event in enumerate(transcript):
        if event.get("type") != "assistant":
            continue
        for item in event.get("message", {}).get("content", []):
            if item.get("type") == "tool_use":
                yield item["name"], item.get("input", {}), bool(event.get("parent_tool_use_id")), i


def load_common(run_dir):
    """Return the run data that the common checks read."""
    reply = run_dir / "outputs" / "final_reply.md"
    diff = run_dir / "repo-diff.txt"
    return {
        "reply": reply.read_text() if reply.exists() else "",
        "tools": list(tool_uses(load_transcript(run_dir))),
        "repo_diff": diff.read_text().strip() if diff.exists() else "missing repo-diff.txt",
    }


def regex_check(check, text, positive):
    hit = [p for p in check["patterns"] if re.search(p, text, re.MULTILINE)]
    if positive:
        missing = [p for p in check["patterns"] if p not in hit]
        return not missing, "all patterns match" if not missing else f"missing: {missing}"
    return not hit, "no pattern matches" if not hit else f"matched: {hit}"


def common_check(check, run):
    """Return (passed, evidence), or None if the check type is not a common one."""
    t = check["type"]
    if t == "repo_unchanged":
        diff = run["repo_diff"]
        return diff == "", "repo-diff.txt is empty" if diff == "" else diff[:300]
    if t == "tool_count":
        scope = check.get("scope", "all")
        hits = []
        for name, inp, sub, _ in run["tools"]:
            if scope == "main" and sub or scope == "sub" and not sub:
                continue
            if not re.fullmatch(check["tool"], name):
                continue
            raw = json.dumps(inp)
            if check.get("input_regex") and not re.search(check["input_regex"], raw):
                continue
            if check.get("input_not_regex") and re.search(check["input_not_regex"], raw):
                continue
            hits.append(f"{name} {raw[:120]}")
        n = len(hits)
        ok = n >= check.get("min", 0) and n <= check.get("max", n)
        return ok, f"{n} call(s)" + (f": {hits[:3]}" if hits else "")
    if t == "parallel_agents":
        per_message = {}
        for name, _, sub, i in run["tools"]:
            if name in ("Agent", "Task") and not sub:
                per_message[i] = per_message.get(i, 0) + 1
        best = max(per_message.values(), default=0)
        return best >= check["min"], f"max {best} agent call(s) in one message"
    if t in ("reply_regex", "reply_not_regex"):
        return regex_check(check, run["reply"], t == "reply_regex")
    return None


def checks_for(spec, ev):
    common = [] if ev.get("common") is False else spec["common_checks"]
    skip = set(ev.get("common_skip", []))
    return [c for c in common if c.get("id") not in skip] + ev["checks"]


def grade_run(run_dir, checks, load_run, run_check):
    """Apply `checks` to one run and write grading.json.

    `load_run(run_dir)` returns the run data. `run_check(check, run)` returns (passed, evidence).
    """
    run = load_run(run_dir)
    expectations = []
    for check in checks:
        try:
            passed, evidence = run_check(check, run)
        except Exception as e:  # a broken check must not hide the other results
            passed, evidence = False, f"check error: {e!r}"
        expectations.append({"text": check["text"], "passed": bool(passed), "evidence": evidence})
    n = sum(e["passed"] for e in expectations)
    result = {
        "expectations": expectations,
        "summary": {"passed": n, "failed": len(expectations) - n, "total": len(expectations),
                    "pass_rate": round(n / len(expectations), 2) if expectations else 0.0},
    }
    (run_dir / "grading.json").write_text(json.dumps(result, indent=2))
    return result


def grade_main(doc, evals_path, grade):
    """CLI for a skill's grade.py. `grade(run_dir, checks)` grades one run."""
    if len(sys.argv) != 2:
        sys.exit(doc)
    iteration = Path(sys.argv[1])
    spec = json.loads(Path(evals_path).read_text())
    for ev in spec["evals"]:
        eval_dir = iteration / f"eval-{ev['name']}"
        if not eval_dir.is_dir():
            continue
        for run_dir in sorted(eval_dir.glob("*/run-*")):
            result = grade(run_dir, checks_for(spec, ev))
            s = result["summary"]
            failed = [e["text"] for e in result["expectations"] if not e["passed"]]
            print(f"{run_dir.relative_to(iteration)}: {s['passed']}/{s['total']}"
                  + "".join(f"\n  FAIL {t}" for t in failed))


def run_main(doc, evals_dir, prefix, allowed_tools, add_dirs, setup, collect, grade):
    """CLI for a skill's run.py.

    Usage: run.py <iteration-dir> [-n RUNS] [-j JOBS] [--model MODEL] [--timeout SEC] [EVAL ...]

    `setup(ev, k, repos, run_dir)` builds the fixture and returns a dict with `repo` (the
    cwd for claude) and `prompt`. `collect(ev, ctx, run_dir)` saves the skill-specific outputs.
    `grade(run_dir, checks)` grades one run.
    """
    p = argparse.ArgumentParser(description=doc, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("iteration_dir", type=Path)
    p.add_argument("evals", nargs="*", help="eval names (default: all except slow)")
    p.add_argument("-n", "--runs", type=int, default=3)
    p.add_argument("-j", "--jobs", type=int, default=4)
    p.add_argument("--model")
    p.add_argument("--timeout", type=int, default=900)
    args = p.parse_args()

    spec = json.loads((evals_dir / "evals.json").read_text())
    by_name = {ev["name"]: ev for ev in spec["evals"]}
    unknown = [n for n in args.evals if n not in by_name]
    if unknown:
        sys.exit(f"unknown eval(s): {unknown}. Known: {list(by_name)}")
    selected = [by_name[n] for n in args.evals] or [ev for ev in spec["evals"] if not ev.get("slow")]

    iteration = args.iteration_dir.resolve()
    repos = Path(tempfile.mkdtemp(prefix=prefix))
    jobs = []
    for ev in selected:
        eval_dir = iteration / f"eval-{ev['name']}"
        eval_dir.mkdir(parents=True, exist_ok=True)
        (eval_dir / "eval_metadata.json").write_text(json.dumps({
            "eval_id": ev["id"], "eval_name": ev["name"], "prompt": ev["prompt"],
            "assertions": [c["text"] for c in checks_for(spec, ev)],
        }, indent=2))
        for k in range(1, args.runs + 1):
            run_dir = eval_dir / CONFIG / f"run-{k}"
            if run_dir.exists():
                sys.exit(f"{run_dir} exists. Use a new iteration dir.")
            print(f"setup {ev['name']} run-{k}", flush=True)
            (run_dir / "outputs").mkdir(parents=True)
            ctx = setup(ev, k, repos, run_dir)
            snapshot(ctx["repo"], run_dir, "before.txt")
            jobs.append((ev, k, run_dir, ctx))
    print(f"{len(jobs)} run(s), repos in {repos}", flush=True)

    def work(job):
        ev, k, run_dir, ctx = job
        seconds = run_claude(ctx["prompt"], ctx["repo"], run_dir, allowed_tools, add_dirs,
                             args.model, args.timeout)
        collect_result(run_dir, seconds)
        collect(ev, ctx, run_dir)
        snapshot(ctx["repo"], run_dir, "after.txt")
        write_repo_diff(run_dir)
        s = grade(run_dir, checks_for(spec, ev))["summary"]
        line = f"{ev['name']} run-{k}: {s['passed']}/{s['total']} in {seconds:.0f}s"
        if json.loads((run_dir / "timing.json").read_text())["is_error"]:
            reply = (run_dir / "outputs" / "final_reply.md").read_text().strip()
            line += f" ERROR: {reply[:200] or 'no result, see stderr.txt'}"
        print(line, flush=True)

    with ThreadPoolExecutor(args.jobs) as pool:
        list(pool.map(work, jobs))
    print(f"\nGrade again: {evals_dir / 'grade.py'} {iteration}")
    print(f"Compare:     {HERE / 'compare.py'} <previous-iteration-dir> {iteration}")
