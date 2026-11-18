#!/usr/bin/env bash
# Usage: rename-key.sh <repo-dir>
# The config key `timeout` in config.py, two tests, and README.md. Prints `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
allow_commits

put config.py <<'PY'
DEFAULTS = {"timeout": 30, "retries": 3}


def load(overrides):
    """Return the defaults with `overrides` on top. Unknown keys raise `KeyError`."""
    unknown = set(overrides) - set(DEFAULTS)
    if unknown:
        raise KeyError(f"unknown config keys: {sorted(unknown)}")
    return {**DEFAULTS, **overrides}
PY

put test_config.py <<'PY'
import unittest

from config import load


class LoadTest(unittest.TestCase):
    def test_overrides_timeout(self):
        self.assertEqual(load({"timeout": 5})["timeout"], 5)

    def test_keeps_default_timeout(self):
        self.assertEqual(load({"retries": 1})["timeout"], 30)


if __name__ == "__main__":
    unittest.main()
PY

put README.md <<'MD'
# Client config

| Key | Default | Meaning |
| --- | --- | --- |
| `timeout` | 30 | Seconds to wait for a response |
| `retries` | 3 | Attempts after the first failure |

Example: `load({"timeout": 5})`.
MD
commit "Add config"
echo "base=$(git rev-parse HEAD)"
