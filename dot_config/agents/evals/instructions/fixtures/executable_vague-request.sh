#!/usr/bin/env bash
# Usage: vague-request.sh <repo-dir>
# cache.py has two slow spots: `get` scans a list of pairs, and `set` writes the whole file each
# time. "Make the cache faster" can mean either one. Prints `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
allow_commits

put cache.py <<'PY'
import json


class FileCache:
    """A key-value cache that keeps its entries in a JSON file."""

    def __init__(self, path):
        self.path = path
        self.entries = []

    def get(self, key):
        for entry_key, value in self.entries:
            if entry_key == key:
                return value
        return None

    def set(self, key, value):
        self.entries = [(k, v) for k, v in self.entries if k != key] + [(key, value)]
        with open(self.path, "w") as file:
            json.dump(self.entries, file)
PY

put test_cache.py <<'PY'
import tempfile
import unittest
from pathlib import Path

from cache import FileCache


class FileCacheTest(unittest.TestCase):
    def test_get_returns_the_last_value(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = FileCache(Path(tmp) / "cache.json")
            cache.set("a", 1)
            cache.set("a", 2)
            self.assertEqual(cache.get("a"), 2)


if __name__ == "__main__":
    unittest.main()
PY
commit "Add file cache"
echo "base=$(git rev-parse HEAD)"
