#!/usr/bin/env python3
"""Grade review-branch eval runs against the checks in evals.json.

Usage: grade.py <iteration-dir>

Reads each <iteration-dir>/eval-<name>/<config>/run-<k>/ and writes grading.json there, in the
format that skill-creator's aggregate_benchmark and eval viewer read. A run dir has:
outputs/<report>.md, outputs/final_reply.md, transcript.jsonl, repo-diff.txt, and
previous-report.md (re-review only).
"""
import json
import re
import sys
from pathlib import Path

EVALS = Path(__file__).resolve().parent / "evals.json"
SECTIONS = {"critical": "C", "high": "H", "medium": "M", "low": "L"}
FLAGS = re.IGNORECASE | re.MULTILINE


def parse_findings(md):
    """Return the finding bullets under `## Findings`, with section, id, location, and text."""
    findings, section, current, in_findings = [], None, None, False
    for line in md.splitlines():
        if line.startswith("## "):
            in_findings = line.strip().lower() == "## findings"
            section = current = None
            continue
        if line.startswith("### "):
            name = line[4:].strip().lower()
            section = name if in_findings and name in SECTIONS else None
            current = None
            continue
        if section and line.startswith("- "):
            m = re.match(r"- \*\*([A-Z])(\d+)\*\*", line)
            loc = re.search(r"`([^`\s:]+):L?(\d+)(?:-L?(\d+))?`", line) or re.search(
                r"`([^`\s:]+\.\w+)`", line
            )
            start = int(loc.group(2)) if loc and loc.lastindex and loc.lastindex >= 2 else None
            end = int(loc.group(3)) if loc and loc.lastindex == 3 and loc.group(3) else start
            current = {
                "id": f"{m.group(1)}{m.group(2)}" if m else None,
                "letter": m.group(1) if m else None,
                "ordinal": int(m.group(2)) if m else None,
                "section": section,
                "file": loc.group(1) if loc else "",
                "start": start,
                "end": end,
                "head": line,
                "text": line,
            }
            findings.append(current)
            continue
        if current and (line.startswith(" ") or not line.strip()):
            current["text"] += "\n" + line
        else:
            current = None
    return findings


def block(md, finding_id):
    for f in parse_findings(md):
        if f["id"] == finding_id:
            return " ".join(f["text"].split())
    return None


def tool_uses(transcript):
    """Yield (name, input, is_subagent, message_index) for each tool call in the transcript."""
    for i, event in enumerate(transcript):
        if event.get("type") != "assistant":
            continue
        for item in event.get("message", {}).get("content", []):
            if item.get("type") == "tool_use":
                yield item["name"], item.get("input", {}), bool(event.get("parent_tool_use_id")), i


def matches(f, check):
    if check.get("file") and not re.search(check["file"], f["file"], re.IGNORECASE):
        return False
    if check.get("lines"):
        lo, hi = check["lines"]
        if f["start"] is None or f["end"] < lo or f["start"] > hi:
            return False
    if check.get("severity") and f["section"] not in check["severity"]:
        return False
    if f["id"] in check.get("except_ids", []):
        return False
    if check.get("any") and not any(re.search(p, f["text"], FLAGS) for p in check["any"]):
        return False
    if check.get("all") and not all(re.search(p, f["text"], FLAGS) for p in check["all"]):
        return False
    return True


def run_check(check, run):
    """Return (passed, evidence)."""
    t, report, reply, findings = check["type"], run["report"], run["reply"], run["findings"]
    if t == "report_count":
        n = len(run["reports"])
        return n == check["equals"], f"{n} report(s): {[p.name for p in run['reports']]}"
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
        hit = [p for p in check["patterns"] if re.search(p, reply, re.MULTILINE)]
        if t == "reply_regex":
            missing = [p for p in check["patterns"] if p not in hit]
            return not missing, "all patterns match" if not missing else f"missing: {missing}"
        return not hit, "no pattern matches" if not hit else f"matched: {hit}"
    if t == "reply_lists_findings":
        missing = [f["id"] for f in findings if f["id"] and not re.search(rf"\b{f['id']}\b", reply)]
        return not missing, f"{len(findings)} finding(s)" + (f", missing {missing}" if missing else "")
    if report is None:
        return False, "no single report to check"
    if t == "report_name":
        name = run["reports"][0].name
        return bool(re.search(check["pattern"], name)), name
    if t in ("report_regex", "report_not_regex"):
        hit = [p for p in check["patterns"] if re.search(p, report, re.MULTILINE)]
        if t == "report_regex":
            missing = [p for p in check["patterns"] if p not in hit]
            return not missing, "all patterns match" if not missing else f"missing: {missing}"
        return not hit, "no pattern matches" if not hit else f"matched: {hit}"
    if t == "finding":
        hit = [f for f in findings if matches(f, check)]
        return bool(hit), hit[0]["head"] if hit else f"no match among {len(findings)} finding(s)"
    if t == "no_finding":
        hit = [f for f in findings if matches(f, check)]
        return not hit, "none" if not hit else hit[0]["head"]
    if t == "ids_valid":
        bad, seen = [], set()
        for f in findings:
            if f["id"] is None or f["letter"] != SECTIONS[f["section"]] or f["id"] in seen:
                bad.append(f["head"][:80])
            seen.add(f["id"])
        if check.get("contiguous"):
            for section in SECTIONS:
                ordinals = [f["ordinal"] for f in findings if f["section"] == section]
                if ordinals != list(range(1, len(ordinals) + 1)):
                    bad.append(f"{section} ordinals {ordinals}")
        return not bad, "ok" if not bad else f"bad: {bad}"
    if t == "counts_match":
        m = re.search(r"\*\*Counts:\*\* (\d+) critical, (\d+) high, (\d+) medium, (\d+) low", report)
        if not m:
            return False, "no Counts line"
        actual = [sum(f["section"] == s for f in findings) for s in SECTIONS]
        stated = [int(x) for x in m.groups()]
        return stated == actual, f"stated {stated}, actual {actual}"
    if t == "adjacent_capped":
        bad = [
            f["head"][:80]
            for f in findings
            if "(adjacent)" in f["head"]
            and (f["section"] not in ("medium", "low") or not re.search(r"\d|\b(one|two|three|single|only)\b", f["text"], FLAGS))
        ]
        n = sum("(adjacent)" in f["head"] for f in findings)
        return not bad, f"{n} adjacent finding(s)" + (f", bad: {bad}" if bad else "")
    if t == "same_as_previous":
        old, new = block(run["previous"], check["id"]), block(report, check["id"])
        if new is None:
            return False, f"{check['id']} not in the report"
        return old == new, "identical" if old == new else f"was: {old}\nnow: {new}"
    raise ValueError(f"unknown check type {t}")


def load_run(run_dir):
    outputs = run_dir / "outputs"
    reports = sorted(p for p in outputs.glob("*.md") if p.name != "final_reply.md")
    transcript = []
    tpath = run_dir / "transcript.jsonl"
    if tpath.exists():
        for line in tpath.read_text().splitlines():
            try:
                transcript.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    report = reports[0].read_text() if len(reports) == 1 else None
    reply_path = outputs / "final_reply.md"
    previous = run_dir / "previous-report.md"
    diff = run_dir / "repo-diff.txt"
    return {
        "reports": reports,
        "report": report,
        "findings": parse_findings(report) if report else [],
        "reply": reply_path.read_text() if reply_path.exists() else "",
        "previous": previous.read_text() if previous.exists() else "",
        "tools": list(tool_uses(transcript)),
        "repo_diff": diff.read_text().strip() if diff.exists() else "missing repo-diff.txt",
    }


def checks_for(spec, ev):
    common = [] if ev.get("common") is False else spec["common_checks"]
    skip = set(ev.get("common_skip", []))
    return [c for c in common if c.get("id") not in skip] + ev["checks"]


def grade_run(run_dir, checks):
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


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    iteration = Path(sys.argv[1])
    spec = json.loads(EVALS.read_text())
    for ev in spec["evals"]:
        eval_dir = iteration / f"eval-{ev['name']}"
        if not eval_dir.is_dir():
            continue
        checks = checks_for(spec, ev)
        for run_dir in sorted(eval_dir.glob("*/run-*")):
            s = grade_run(run_dir, checks)["summary"]
            failed = [e["text"] for e in json.loads((run_dir / "grading.json").read_text())["expectations"] if not e["passed"]]
            rel = run_dir.relative_to(iteration)
            print(f"{rel}: {s['passed']}/{s['total']}" + "".join(f"\n  FAIL {t}" for t in failed))


if __name__ == "__main__":
    main()
