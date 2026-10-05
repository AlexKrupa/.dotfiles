#!/usr/bin/env python3
"""Grade review-diff eval runs against the checks in evals.json.

Usage: grade.py <iteration-dir>

Reads each <iteration-dir>/eval-<name>/<config>/run-<k>/ and writes grading.json there, in the
format that skill-creator's aggregate_benchmark and eval viewer read. A run dir has:
outputs/<report>.md, outputs/final_reply.md, transcript.jsonl, repo-diff.txt, and
previous-report.md (re-review only).
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "evals"))
import harness  # noqa: E402

EVALS = HERE / "evals.json"
SECTIONS = {"critical": "C", "high": "H", "medium": "M", "low": "L"}
FLAGS = harness.FLAGS


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


def parse_impact(md):
    """Return the numbered items under `## High-impact changes`, or None when there is no section."""
    items, in_section = None, False
    for line in md.splitlines():
        if line.startswith("## "):
            in_section = line.strip().lower() == "## high-impact changes"
            if in_section:
                items = []
            continue
        if not in_section:
            continue
        if re.match(r"\d+\. ", line):
            items.append(line)
        elif items and (line.startswith(" ") or not line.strip()):
            items[-1] += "\n" + line
    return items


def block(md, finding_id):
    for f in parse_findings(md):
        if f["id"] == finding_id:
            return " ".join(f["text"].split())
    return None


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
    if any(re.search(p, f["text"], FLAGS) for p in check.get("none", [])):
        return False
    return True


def run_check(check, run):
    """Return (passed, evidence)."""
    t, report, reply, findings = check["type"], run["report"], run["reply"], run["findings"]
    common = harness.common_check(check, run)
    if common is not None:
        return common
    if t == "report_count":
        n = len(run["reports"])
        return n == check["equals"], f"{n} report(s): {[p.name for p in run['reports']]}"
    if t == "reply_lists_findings":
        missing = [f["id"] for f in findings if f["id"] and not re.search(rf"\b{f['id']}\b", reply)]
        return not missing, f"{len(findings)} finding(s)" + (f", missing {missing}" if missing else "")
    if report is None:
        return False, "no single report to check"
    if t == "report_name":
        name = run["reports"][0].name
        return bool(re.search(check["pattern"], name)), name
    if t in ("report_regex", "report_not_regex"):
        return harness.regex_check(check, report, t == "report_regex")
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
    if t in ("impact_item", "no_impact_item"):
        items = parse_impact(report) or []
        hit = [
            i for i in items
            if (not check.get("any") or any(re.search(p, i, FLAGS) for p in check["any"]))
            and all(re.search(p, i, FLAGS) for p in check.get("all", []))
        ]
        found = hit[0].splitlines()[0] if hit else f"no match among {len(items)} item(s)"
        return bool(hit) == (t == "impact_item"), found
    if t == "impact_count":
        items = parse_impact(report)
        n = sum(1 for i in items or [] if not check.get("any") or any(re.search(p, i, FLAGS) for p in check["any"]))
        ok = check.get("min", 0) <= n <= check.get("max", n)
        return ok, f"{n} item(s)" + ("" if items is not None else ", no section")
    if t == "impact_format":
        items = parse_impact(report)
        if items is None:
            return True, "no section"
        if not items:
            return False, "empty section - omit it instead"
        if not re.search(r"(?i)high-impact", reply):
            return False, f"{len(items)} item(s), final reply does not list them"
        return True, f"{len(items)} item(s), listed in the final reply"
    if t == "same_as_previous":
        old, new = block(run["previous"], check["id"]), block(report, check["id"])
        if new is None:
            return False, f"{check['id']} not in the report"
        return old == new, "identical" if old == new else f"was: {old}\nnow: {new}"
    raise ValueError(f"unknown check type {t}")


def load_run(run_dir):
    outputs = run_dir / "outputs"
    reports = sorted(p for p in outputs.glob("*.md") if p.name != "final_reply.md")
    report = reports[0].read_text() if len(reports) == 1 else None
    previous = run_dir / "previous-report.md"
    return {
        **harness.load_common(run_dir),
        "reports": reports,
        "report": report,
        "findings": parse_findings(report) if report else [],
        "previous": previous.read_text() if previous.exists() else "",
    }


def grade_run(run_dir, checks):
    return harness.grade_run(run_dir, checks, load_run, run_check)


if __name__ == "__main__":
    harness.grade_main(__doc__, EVALS, grade_run)
