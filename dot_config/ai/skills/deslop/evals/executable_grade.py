#!/usr/bin/env python3
"""Grade deslop eval runs against the checks in evals.json.

Usage: grade.py <iteration-dir>

Reads each <iteration-dir>/eval-<name>/<config>/run-<k>/ and writes grading.json there. A run dir
has: ctx.json (base and head sha, index diff), applied/ (a clone after the autosquash rebase, or a
copy of the working tree), rebase.txt, outputs/ (final reply, logs, diffs, status, index),
transcript.jsonl, before.txt, after.txt, repo-diff.txt, and before-tree/ (the working tree before
the run). A `patterns` value that starts with `@` names a list in `pattern_sets`.
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
FLAGS = harness.FLAGS


def split_comments(src):
    """Return (code_lines, comment_lines) of C-style source. Ignores `//` in string literals."""
    code, comments, in_block = [], [], False
    for line in src.splitlines():
        kept, note, rest, in_string = "", "", line, False
        while rest:
            if in_block:
                end = rest.find("*/")
                note += rest if end < 0 else rest[:end]
                rest, in_block = ("", True) if end < 0 else (rest[end + 2:], False)
                continue
            ch = rest[0]
            if ch == '"':
                in_string = not in_string
            if not in_string and rest.startswith("//"):
                note += rest[2:]
                break
            if not in_string and rest.startswith("/*"):
                rest, in_block = rest[2:], True
                continue
            kept, rest = kept + ch, rest[1:]
        if kept.strip():
            code.append(kept.strip())
        if note.strip(" *"):
            comments.append(note.strip(" *"))
    return code, comments


def git_show(applied, ref, path):
    p = subprocess.run(["git", "-C", str(applied), "show", f"{ref}:{path}"],
                       capture_output=True, text=True)
    return p.stdout if p.returncode == 0 else None


def run_check(check, run):
    """Return (passed, evidence)."""
    common = harness.common_check(check, run)
    if common is not None:
        return common
    t = check["type"]
    if t == "rebase_clean":
        return run["rebase"].startswith("rc=0"), run["rebase"][:300] or "no rebase.txt"
    if t == "worktree_clean":
        status = run["outputs"].get("status.txt")
        return status == "", "clean" if status == "" else f"status: {status!r}"
    if t == "commit_count":
        n = len(run["applied_subjects"])
        return n == check["equals"], f"{n} commit(s): {run['applied_subjects']}"
    if t == "new_commits":
        subjects = run["new_subjects"]
        bad = [s for s in subjects if check.get("all_regex") and not re.search(check["all_regex"], s)]
        bad += [s for s in subjects if check.get("none_regex") and re.search(check["none_regex"], s)]
        ok = not bad and len(subjects) >= check.get("min", 0)
        return ok, f"{len(subjects)} new commit(s): {subjects}" + (f", bad: {bad}" if bad else "")
    if t in ("log_regex", "log_not_regex"):
        return regex(check, run["outputs"].get("applied-log.txt", ""), t == "log_regex")
    if t == "new_text_not_regex":
        # Reply mode adds one line below the new text that names the removed data.
        text = "\n".join(ln for ln in run["reply"].splitlines() if not ln.startswith("Removed"))
        return regex(check, text, False)
    if t == "index_same":
        same = run["outputs"].get("index.txt") == run["ctx"]["index"]
        return same, "index unchanged" if same else f"index now: {run['outputs'].get('index.txt', '')[:300]!r}"
    if t == "refs_same":
        changed = [r for r in check["refs"] if run["refs_before"].get(r) != run["refs_after"].get(r)]
        return not changed, "unchanged" if not changed else f"changed: {changed}"

    text = (run["applied"] / check["path"]).read_text() if (run["applied"] / check["path"]).exists() else None
    if text is None:
        return False, f"{check['path']} missing after the rebase"
    if t in ("file_regex", "file_not_regex"):
        return regex(check, text, t == "file_regex")
    if t == "file_same":
        old = git_show(run["applied"], run["ctx"][check["ref"]], check["path"])
        return text == old, "identical" if text == old else f"changed, now: {text[:300]!r}"
    if t == "line_max":
        long = [ln for ln in text.splitlines() if len(ln) > check["max"]]
        return not long, "ok" if not long else f"{len(long)} long line(s): {long[0][:80]!r}"
    code, comments = split_comments(text)
    if t in ("comments_regex", "comments_not_regex"):
        return regex(check, "\n".join(comments), t == "comments_regex")
    if t == "comment_count":
        return len(comments) <= check["max"], f"{len(comments)} comment line(s): {comments}"
    if t == "code_same":
        if check.get("ref") == "before":
            old_path = run["dir"] / "before-tree" / check["path"]
            old = old_path.read_text() if old_path.exists() else ""
        else:
            old = git_show(run["applied"], run["ctx"]["head"], check["path"]) or ""
        old_code, _ = split_comments(old)
        if code == old_code:
            return True, "code lines identical"
        diff = [ln for ln in code if ln not in old_code] + [ln for ln in old_code if ln not in code]
        return False, f"code differs: {diff[:4]}"
    raise ValueError(f"unknown check type {t}")


def regex(check, text, positive):
    """Like harness.regex_check, but case-insensitive unless the check sets `case`."""
    flags = re.MULTILINE if check.get("case") else FLAGS
    hit = [p for p in check["patterns"] if re.search(p, text, flags)]
    if positive:
        missing = [p for p in check["patterns"] if p not in hit]
        return not missing, "all patterns match" if not missing else f"missing: {missing}"
    found = [re.search(p, text, flags).group(0) for p in hit]
    return not hit, "no pattern matches" if not hit else f"matched: {found}"


def refs(snapshot_path):
    if not snapshot_path.exists():
        return {}
    return dict(ln.split(" ", 1) for ln in snapshot_path.read_text().splitlines()
                if ln.startswith("refs/"))


def load_run(run_dir):
    outputs = run_dir / "outputs"
    rebase = run_dir / "rebase.txt"
    texts = {p.name: p.read_text() for p in outputs.glob("*.txt")}
    return {
        **harness.load_common(run_dir),
        "dir": run_dir,
        "ctx": json.loads((run_dir / "ctx.json").read_text()),
        "applied": run_dir / "applied",
        "rebase": rebase.read_text() if rebase.exists() else "",
        "outputs": texts,
        "new_subjects": subjects(texts.get("new-commits.txt", "")),
        "applied_subjects": subjects(texts.get("applied-log.txt", "")),
        "refs_before": refs(run_dir / "before.txt"),
        "refs_after": refs(run_dir / "after.txt"),
    }


def subjects(log):
    """Subjects from `git log --format='%h %s%n%b'` output."""
    return [ln.split(" ", 1)[1] for ln in log.splitlines()
            if re.match(r"^[0-9a-f]{7,} ", ln) and " " in ln]


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
