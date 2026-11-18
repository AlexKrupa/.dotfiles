import json
import os
import tempfile
import unittest
from pathlib import Path

import harness


def event(five_hour, seven_day):
    return json.dumps({"type": "rate_limit_event", "rate_limit_info": {"unifiedWindows": {
        "five_hour": {"utilization": five_hour, "resetsAt": 1791674400},
        "seven_day": {"utilization": seven_day, "resetsAt": 1791900000}}}})


def limits(five_hour, seven_day):
    return {"five_hour": five_hour, "seven_day": seven_day,
            "five_hour_resets": 1791674400, "seven_day_resets": 1791900000}


class RateLimitsTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.mtime = 1_700_000_000

    def tearDown(self):
        self.dir.cleanup()

    def transcript(self, name, *lines):
        path = Path(self.dir.name) / name
        path.write_text("".join(line + "\n" for line in lines))
        self.mtime += 10
        os.utime(path, (self.mtime, self.mtime))
        return path

    def test_rate_limits_reads_newest_event(self):
        old = self.transcript("old.jsonl", event(0.9, 0.9))
        new = self.transcript("new.jsonl", event(0.5, 0.5), event(0.71, 0.6))

        result = harness.rate_limits([new, old])

        self.assertEqual(result["five_hour"], 71.0)
        self.assertEqual(result["seven_day"], 60.0)
        self.assertEqual(result["five_hour_resets"], 1791674400)

    def test_rate_limits_skips_files_with_no_event(self):
        old = self.transcript("old.jsonl", event(0.3, 0.2))
        empty_new = self.transcript("new.jsonl", '{"type":"system","subtype":"init"}')

        self.assertEqual(harness.rate_limits([old, empty_new])["five_hour"], 30.0)

    def test_rate_limits_returns_none_with_no_events(self):
        empty = self.transcript("empty.jsonl", "not json")
        missing = Path(self.dir.name) / "missing.jsonl"

        self.assertIsNone(harness.rate_limits([empty, missing]))


class GuardReasonTest(unittest.TestCase):
    def test_guard_stops_at_five_hour_limit(self):
        self.assertIn("5h", harness.guard_reason(limits(80.0, 10.0), 80, 50))

    def test_guard_stops_at_seven_day_limit(self):
        self.assertIn("7d", harness.guard_reason(limits(10.0, 50.0), 80, 50))

    def test_guard_allows_below_limits(self):
        self.assertIsNone(harness.guard_reason(limits(79.9, 49.9), 80, 50))

    def test_guard_allows_with_no_limits(self):
        self.assertIsNone(harness.guard_reason(None, 80, 50))


if __name__ == "__main__":
    unittest.main()
