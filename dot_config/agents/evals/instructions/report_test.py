import json
import tempfile
import unittest
from pathlib import Path

import report


class VerdictTest(unittest.TestCase):
    def test_candidate_when_none_passes_90_percent(self):
        self.assertEqual(report.verdict(none=[True] * 9 + [False], full=[True] * 9 + [False]), "candidate")

    def test_keep_when_full_is_better(self):
        self.assertEqual(report.verdict(none=[True] * 9 + [False], full=[True] * 10), "keep")

    def test_keep_when_none_below_90_percent(self):
        self.assertEqual(report.verdict(none=[True] * 8 + [False] * 2, full=[True] * 8 + [False] * 2), "keep")

    def test_insufficient_with_few_runs(self):
        self.assertEqual(report.verdict(none=[True] * 2, full=[True] * 5), "insufficient")


class RowsTest(unittest.TestCase):
    """Two iteration dirs with one eval: `none` passes check A in all runs, `full` in all runs."""

    SPEC = {"common_checks": [], "evals": [{"name": "e", "checks": [
        {"type": "reply_regex", "patterns": ["x"], "rule": "L7", "text": "A"},
        {"type": "reply_regex", "patterns": ["y"], "rule": "L7,L9", "text": "B"},
        {"type": "reply_regex", "patterns": ["z"], "text": "no rule"}]}]}

    def write_runs(self, root, config, results, is_error=False):
        for k, (a, b) in enumerate(results, 1):
            run_dir = root / "eval-e" / config / f"run-{k}"
            run_dir.mkdir(parents=True)
            expectations = [{"text": "A", "passed": a}, {"text": "B", "passed": b},
                            {"text": "no rule", "passed": True}]
            (run_dir / "grading.json").write_text(json.dumps({"expectations": expectations}))
            (run_dir / "timing.json").write_text(json.dumps({"is_error": is_error, "isolation_problems": []}))

    def test_rows_count_each_rule_of_a_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            none, full = Path(tmp) / "none", Path(tmp) / "full"
            self.write_runs(none, "none", [(True, True)] * 3)
            self.write_runs(full, "full", [(True, False)] * 3)
            self.write_runs(full, "full-error", [(False, False)] * 3, is_error=True)

            rows = report.rows(self.SPEC, none, full)

        self.assertEqual([r["rule"] for r in rows], ["L7", "L9"])
        self.assertEqual(rows[0]["none"], [True] * 6)
        self.assertEqual(rows[0]["full"], [True] * 3 + [False] * 3)
        self.assertEqual(rows[0]["checks"], 2)
        self.assertEqual(rows[1]["verdict"], "candidate")


if __name__ == "__main__":
    unittest.main()
