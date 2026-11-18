#!/usr/bin/env bash
# Usage: commit-this.sh <repo-dir>
# Branch `feat/profile` with `origin`. Two unrelated uncommitted changes: a typo fix in README.md,
# and a new function in profile.py with its test. Prints `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
allow_commits

put README.md <<'MD'
# Profiles

Stores user profiels and their display names.
MD

put profile.py <<'PY'
def display_name(first, last):
    return f"{first} {last}"
PY

put test_profile.py <<'PY'
import unittest

from profile import display_name


class ProfileTest(unittest.TestCase):
    def test_display_name(self):
        self.assertEqual(display_name("Ada", "Lovelace"), "Ada Lovelace")


if __name__ == "__main__":
    unittest.main()
PY
commit "Add profiles"
add_origin
git switch -q -c feat/profile
git push -q -u origin feat/profile
base=$(git rev-parse HEAD)

put README.md <<'MD'
# Profiles

Stores user profiles and their display names.
MD

put profile.py <<'PY'
def display_name(first, last):
    return f"{first} {last}"


def initials(first, last):
    return f"{first[:1]}{last[:1]}".upper()
PY

put test_profile.py <<'PY'
import unittest

from profile import display_name, initials


class ProfileTest(unittest.TestCase):
    def test_display_name(self):
        self.assertEqual(display_name("Ada", "Lovelace"), "Ada Lovelace")

    def test_initials(self):
        self.assertEqual(initials("ada", "lovelace"), "AL")


if __name__ == "__main__":
    unittest.main()
PY
echo "base=$base"
