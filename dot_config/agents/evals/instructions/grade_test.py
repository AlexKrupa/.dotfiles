import json
import os
import tempfile
import unittest
from pathlib import Path

import grade

QUESTIONS = [{"type": "judge", "id": "q1", "question": "Is it fine?", "rule": "L1", "text": "fine"},
             {"type": "judge", "id": "q2", "question": "Is it small?", "rule": "L2", "text": "small"}]
FAKE_CLAUDE = """#!/bin/sh
echo call >> "$(dirname "$0")/calls.txt"
printf '%s' "$FAKE_CLAUDE_OUTPUT"
"""


class JudgeTest(unittest.TestCase):
    """A fake `claude` on PATH prints FAKE_CLAUDE_OUTPUT and logs its calls."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.bin = root / "bin"
        self.bin.mkdir()
        (self.bin / "claude").write_text(FAKE_CLAUDE)
        (self.bin / "claude").chmod(0o755)
        self.run_dir = root / "run-1"
        (self.run_dir / "outputs").mkdir(parents=True)
        (self.run_dir / "ctx.json").write_text(json.dumps({"prompt": "Do it.", "eval": "e"}))
        (self.run_dir / "outputs" / "changes.diff").write_text("+x = 1\n")
        (self.run_dir / "outputs" / "final_reply.md").write_text("Done.")
        self.env = {k: os.environ.get(k) for k in ("PATH", "FAKE_CLAUDE_OUTPUT")}
        os.environ["PATH"] = f"{self.bin}:{os.environ['PATH']}"

    def tearDown(self):
        for key, value in self.env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.tmp.cleanup()

    def calls(self):
        log = self.bin / "calls.txt"
        return log.read_text().splitlines() if log.exists() else []

    def test_judge_uses_cached_answers(self):
        cached = {"q1": {"pass": True, "evidence": "e1"}, "q2": {"pass": False, "evidence": "e2"}}
        (self.run_dir / "judge.json").write_text(json.dumps(cached))

        answers = grade.judge_answers(self.run_dir, QUESTIONS)

        self.assertEqual(answers, cached)
        self.assertEqual(self.calls(), [])
        self.assertEqual(grade.run_check(QUESTIONS[0], {"judge": answers}), (True, "e1"))

    def test_judge_caches_new_answers(self):
        os.environ["FAKE_CLAUDE_OUTPUT"] = json.dumps({"is_error": False, "structured_output": {
            "q1": {"pass": True, "evidence": "e1"}, "q2": {"pass": True, "evidence": "e2"}}})

        grade.judge_answers(self.run_dir, QUESTIONS)
        answers = grade.judge_answers(self.run_dir, QUESTIONS)

        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(answers["q2"], {"pass": True, "evidence": "e2"})

    def test_judge_fails_with_no_answer(self):
        os.environ["FAKE_CLAUDE_OUTPUT"] = json.dumps({"is_error": False, "structured_output": {
            "q1": {"pass": True, "evidence": "e1"}}})

        answers = grade.judge_answers(self.run_dir, QUESTIONS)
        passed, evidence = grade.run_check(QUESTIONS[1], {"judge": answers})

        self.assertFalse(passed)
        self.assertIn("no judge answer", evidence)
        self.assertEqual(grade.run_check(QUESTIONS[0], {"judge": answers}), (True, "e1"))

    def test_judge_fails_with_invalid_output(self):
        os.environ["FAKE_CLAUDE_OUTPUT"] = "not json"

        answers = grade.judge_answers(self.run_dir, QUESTIONS)

        self.assertIn("no judge answer", grade.run_check(QUESTIONS[0], {"judge": answers})[1])
        self.assertFalse((self.run_dir / "judge.json").exists())


def bash(command, result, use_id):
    return [{"type": "assistant", "message": {"id": use_id, "content": [
                {"type": "tool_use", "id": use_id, "name": "Bash", "input": {"command": command}}]}},
            {"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": use_id, "content": [{"type": "text", "text": result}]}]}}]


def edit(path, use_id):
    return [{"type": "assistant", "message": {"id": use_id, "content": [
        {"type": "tool_use", "id": use_id, "name": "Edit", "input": {"file_path": path}}]}}]


TEST_WRITE = {"tool": "Edit|Write", "input_regex": "test_search\\.py"}
FAILING_RUN = {"tool": "Bash", "input_regex": "unittest", "result_regex": "FAILED"}
FIX = {"tool": "Edit|Write", "input_regex": "/search\\.py\""}
ORDER = {"type": "tool_order", "steps": [TEST_WRITE, FAILING_RUN, FIX], "text": "TDD"}


class ToolOrderTest(unittest.TestCase):
    def test_passes_when_test_fails_before_the_fix(self):
        transcript = (edit("/r/test_search.py", "a") + bash("python3 -m unittest test_search", "FAILED (failures=1)", "b")
                      + edit("/r/search.py", "c"))

        self.assertTrue(grade.run_check(ORDER, {"transcript": transcript})[0])

    def test_fails_when_the_fix_comes_first(self):
        transcript = (edit("/r/search.py", "a") + edit("/r/test_search.py", "b")
                      + bash("python3 -m unittest", "FAILED (failures=1)", "c") + edit("/r/search.py", "d"))

        passed, evidence = grade.run_check(ORDER, {"transcript": transcript})

        self.assertFalse(passed)
        self.assertIn("step 3", evidence)

    def test_fails_when_the_test_run_passes(self):
        transcript = (edit("/r/test_search.py", "a") + bash("python3 -m unittest", "OK", "b")
                      + edit("/r/search.py", "c"))

        self.assertFalse(grade.run_check(ORDER, {"transcript": transcript})[0])


class ToolCountAfterTest(unittest.TestCase):
    CHECK = {"type": "tool_count_after", "after": FIX, "tool": "Bash", "input_regex": "unittest\\s*\"",
             "max": 0, "text": "no full run after the fix"}

    def test_counts_only_calls_after_the_first_match(self):
        transcript = bash("python3 -m unittest", "OK", "a") + edit("/r/search.py", "b") + bash(
            "python3 -m unittest test_search", "OK", "c")

        self.assertEqual(grade.run_check(self.CHECK, {"transcript": transcript}), (True, "0 call(s)"))

    def test_fails_on_a_full_run_after_the_fix(self):
        transcript = edit("/r/search.py", "a") + bash("python3 -m unittest", "OK", "b")

        self.assertFalse(grade.run_check(self.CHECK, {"transcript": transcript})[0])


class LineMaxTest(unittest.TestCase):
    def test_fails_on_a_long_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "a.md").write_text("short\n" + "x" * 101 + "\n")
            check = {"type": "line_max", "paths": ["*.md"], "max": 100}

            passed, evidence = grade.run_check(check, {"tree": Path(tmp)})

            self.assertFalse(passed)
            self.assertIn("a.md", evidence)

    def test_passes_at_the_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "a.md").write_text("x" * 100 + "\n")
            check = {"type": "line_max", "paths": ["*.md"], "max": 100}

            self.assertTrue(grade.run_check(check, {"tree": Path(tmp)})[0])


class CommitCountTest(unittest.TestCase):
    def test_checks_the_range(self):
        run = {"commits": ["a1 Add slugify", "b2 Add word_count"]}

        self.assertTrue(grade.run_check({"type": "commit_count", "min": 2}, run)[0])
        self.assertFalse(grade.run_check({"type": "commit_count", "min": 3, "max": 3}, run)[0])


class AddedLinesTest(unittest.TestCase):
    def test_added_lines_keeps_only_matching_files(self):
        diff = ("+++ b/a.py\n+x = 'a'\n-y\n+++ b/README.md\n+\"q\"\n")

        self.assertEqual(grade.added_lines(diff, r"\.py$"), "x = 'a'")


if __name__ == "__main__":
    unittest.main()
