#!/usr/bin/env python3
"""Grade instruction eval runs against the checks in evals.json.

Usage: grade.py <iteration-dir>

Reads each <iteration-dir>/eval-<name>/<condition>/run-<k>/ and writes grading.json there. A run
dir has: ctx.json, after-tree/ (the working tree after the run), outputs/ (final reply,
changes.diff against the fixture base, commits.txt), transcript.jsonl, and timing.json.

Check types on top of the common ones of harness.py:
- `file_regex`, `file_not_regex`: `patterns` on each file in after-tree/ that matches a glob of
  `paths`.
- `line_max`: no line longer than `max` characters in the files of `paths`.
- `commit_count`: the count of new commits since the fixture base is in `min`..`max`.
- `diff_regex`, `diff_not_regex`: `patterns` on the added lines of changes.diff. `path_regex`
  limits the lines to the files whose path matches.
- `tool_order`: `steps`, each with `tool`, and optional `input_regex` and `result_regex` (on the
  tool result). The first call that matches each step comes after the first call of the step before.
- `tool_count_after`: a `tool_count` that counts only the calls after the first call that matches
  `after`.
- `judge`: `question`, a yes or no question where yes means the rule holds. One Sonnet call per run
  answers all judge questions of the eval from the prompt, changes.diff, and the final reply. The
  answers are cached in judge.json. After a change of a question, delete its answer there.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import harness  # noqa: E402

EVALS = HERE / "evals.json"
JUDGE_MODEL = "claude-sonnet-5-5"
JUDGE_PROMPT = """You grade the work of a coding agent against rules. Answer each question only from
the evidence below. Yes (`pass: true`) means that the rule holds. For each answer, give one line of
evidence: a quote or a file and line of the diff or the reply.

## Task prompt

{prompt}

## Diff of the repo against the start (git diff, new files included)

```diff
{diff}
```

## Final reply of the agent

{reply}

## Questions

{questions}
"""


def added_lines(diff, path_regex=None):
    """Return the added lines of a unified diff, without the `+`, for the files that match."""
    lines, keep = [], True
    for line in diff.splitlines():
        if line.startswith("+++ "):
            path = line[4:].removeprefix("b/")
            keep = path_regex is None or re.search(path_regex, path) is not None
        elif line.startswith("+") and keep:
            lines.append(line[1:])
    return "\n".join(lines)


def file_texts(tree, globs):
    return {str(path.relative_to(tree)): path.read_text()
            for pattern in globs for path in sorted(tree.glob(pattern)) if path.is_file()}


def judge_answers(run_dir, questions):
    """Return {question id: {"pass": bool, "evidence": str}} for the judge questions of a run.

    Reads the answers in judge.json, asks the judge only the questions with no answer there, and
    adds the new answers to judge.json. A failed call adds nothing, so a regrade asks again."""
    cache = run_dir / "judge.json"
    cached = json.loads(cache.read_text()) if cache.exists() else {}
    questions = [q for q in questions if q["id"] not in cached]
    if not questions:
        return cached
    ctx = json.loads((run_dir / "ctx.json").read_text())
    outputs = run_dir / "outputs"
    prompt = JUDGE_PROMPT.format(
        prompt=ctx["prompt"], diff=(outputs / "changes.diff").read_text(),
        reply=(outputs / "final_reply.md").read_text(),
        questions="\n".join(f"{i}. `{q['id']}`: {q['question']}" for i, q in enumerate(questions, 1)))
    answer = {"type": "object", "required": ["pass", "evidence"],
              "properties": {"pass": {"type": "boolean"}, "evidence": {"type": "string"}}}
    schema = {"type": "object", "required": [q["id"] for q in questions],
              "properties": {q["id"]: answer for q in questions}}
    # Safe mode loads no CLAUDE.md, plugins, hooks, or MCP servers, which would change the answers.
    try:
        p = subprocess.run(["claude", "-p", prompt, "--model", JUDGE_MODEL, "--safe-mode", "--tools", "",
                            "--output-format", "json", "--no-session-persistence",
                            "--json-schema", json.dumps(schema)],
                           cwd=run_dir, env=harness.claude_env(), capture_output=True, text=True,
                           timeout=600)
        answers = json.loads(p.stdout)["structured_output"]
        if not isinstance(answers, dict):
            raise TypeError(f"structured_output is {answers!r}")
    except (subprocess.TimeoutExpired, json.JSONDecodeError, KeyError, TypeError) as e:
        print(f"judge: no answer for {run_dir}: {e!r}", file=sys.stderr)
        return cached
    answers = {**cached, **answers}
    cache.write_text(json.dumps(answers, indent=2))
    return answers


def tool_calls(transcript):
    """Return (name, input JSON, result text) for each tool call, in transcript order."""
    results = {}
    for event in transcript:
        if event.get("type") != "user":
            continue
        for item in event.get("message", {}).get("content", []):
            if isinstance(item, dict) and item.get("type") == "tool_result":
                content = item.get("content")
                results[item.get("tool_use_id")] = content if isinstance(content, str) else "\n".join(
                    part.get("text", "") for part in content or [] if isinstance(part, dict))
    return [(item["name"], json.dumps(item.get("input", {})), results.get(item.get("id"), ""))
            for event in transcript if event.get("type") == "assistant"
            for item in event.get("message", {}).get("content", []) if item.get("type") == "tool_use"]


def matches(step, call):
    name, raw, result = call
    return (re.fullmatch(step["tool"], name) is not None
            and re.search(step.get("input_regex", ""), raw) is not None
            and re.search(step.get("result_regex", ""), result) is not None)


def first_index(step, calls):
    return next((i for i, call in enumerate(calls) if matches(step, call)), None)


def run_check(check, run):
    """Return (passed, evidence)."""
    t = check["type"]
    if t == "judge":
        answer = run["judge"].get(check["id"])
        if not isinstance(answer, dict) or not isinstance(answer.get("pass"), bool):
            return False, "no judge answer"
        return answer["pass"], answer.get("evidence", "")
    if t == "tool_order":
        calls = tool_calls(run["transcript"])
        previous = -1
        for number, step in enumerate(check["steps"], 1):
            index = first_index(step, calls)
            if index is None:
                return False, f"step {number} has no call: {step}"
            if index < previous:
                return False, f"step {number} first comes at call {index}, before step {number - 1}"
            previous = index
        return True, "steps in order"
    if t == "tool_count_after":
        calls = tool_calls(run["transcript"])
        start = first_index(check["after"], calls)
        later = [] if start is None else [c for c in calls[start + 1:] if matches(check, c)]
        count = len(later)
        passed = check.get("min", 0) <= count <= check.get("max", count)
        return passed, f"{count} call(s)" + (f": {[raw[:120] for _, raw, _ in later[:3]]}" if later else "")
    if t in ("file_regex", "file_not_regex"):
        texts = file_texts(run["tree"], check["paths"])
        if not texts:
            return False, f"no file matches {check['paths']}"
        results = {path: harness.regex_check(check, text, t == "file_regex")
                   for path, text in texts.items()}
        failed = {path: evidence for path, (passed, evidence) in results.items() if not passed}
        return not failed, f"{len(texts)} file(s) ok" if not failed else f"{failed}"
    if t == "line_max":
        long_lines = [f"{path}:{number}" for path, text in file_texts(run["tree"], check["paths"]).items()
                      for number, line in enumerate(text.splitlines(), 1) if len(line) > check["max"]]
        return not long_lines, "ok" if not long_lines else f"{len(long_lines)} long line(s): {long_lines[:5]}"
    if t == "commit_count":
        count = len(run["commits"])
        passed = check.get("min", 0) <= count <= check.get("max", count)
        return passed, f"{count} commit(s): {run['commits'][:5]}"
    if t in ("diff_regex", "diff_not_regex"):
        return harness.regex_check(check, added_lines(run["diff"], check.get("path_regex")),
                                   t == "diff_regex")
    raise ValueError(f"unknown check type {t}")


def judge_questions(eval_name):
    spec = json.loads(EVALS.read_text())
    ev = next(ev for ev in spec["evals"] if ev["name"] == eval_name)
    return [c for c in harness.checks_for(spec, ev) if c["type"] == "judge"]


def load_run(run_dir):
    outputs = run_dir / "outputs"
    ctx = json.loads((run_dir / "ctx.json").read_text())
    questions = judge_questions(ctx["eval"])
    diff = outputs / "changes.diff"
    commits = outputs / "commits.txt"
    return {
        **harness.load_common(run_dir),
        "dir": run_dir,
        "ctx": ctx,
        "tree": run_dir / "after-tree",
        "diff": diff.read_text() if diff.exists() else "",
        "commits": commits.read_text().splitlines() if commits.exists() else [],
        "transcript": harness.load_transcript(run_dir),
        "judge": judge_answers(run_dir, questions) if questions else {},
    }


if __name__ == "__main__":
    harness.grade_main(__doc__, EVALS, load_run, run_check)
