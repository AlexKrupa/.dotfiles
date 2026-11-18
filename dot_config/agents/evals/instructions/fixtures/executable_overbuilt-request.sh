#!/usr/bin/env bash
# Usage: overbuilt-request.sh <repo-dir>
# export.py has one JSON export function of about 20 lines. Prints `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
allow_commits

put export.py <<'PY'
import json
from datetime import date


def export_json(orders, path):
    """Write `orders` to `path` as a JSON list, newest first."""
    rows = []
    for order in sorted(orders, key=lambda order: order["created"], reverse=True):
        rows.append({
            "id": order["id"],
            "customer": order["customer"],
            "total_cents": order["total_cents"],
            "created": order["created"].isoformat(),
        })
    with open(path, "w") as file:
        json.dump(rows, file, indent=2)


if __name__ == "__main__":
    export_json([{"id": 1, "customer": "Ada", "total_cents": 1250, "created": date(2026, 1, 2)}],
                "orders.json")
PY

put test_export.py <<'PY'
import json
import tempfile
import unittest
from datetime import date
from pathlib import Path

from export import export_json


class ExportJsonTest(unittest.TestCase):
    def test_writes_newest_order_first(self):
        orders = [{"id": 1, "customer": "Ada", "total_cents": 100, "created": date(2026, 1, 1)},
                  {"id": 2, "customer": "Bob", "total_cents": 200, "created": date(2026, 1, 2)}]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "orders.json"
            export_json(orders, path)
            self.assertEqual([row["id"] for row in json.loads(path.read_text())], [2, 1])


if __name__ == "__main__":
    unittest.main()
PY
commit "Add JSON export"
echo "base=$(git rev-parse HEAD)"
