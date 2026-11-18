#!/usr/bin/env bash
# Usage: readme-rule.sh <repo-dir>
# README.md asks for `make check` before the end and for camelCase JSON keys. The existing keys
# are single words, so the code does not show the key style. The code uses single quotes.
# Prints `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
allow_commits

put README.md <<'MD'
# Users

The user model of the account service.

## Rules

- Run `make check` before you finish.
- JSON keys are camelCase.
MD

put Makefile <<'MAKE'
check:
	python3 -m unittest
MAKE

put user.py <<'PY'
import json


class User:
    def __init__(self, id, name):
        self.id = id
        self.name = name

    def to_json(self):
        return json.dumps({'id': self.id, 'name': self.name})
PY

put test_user.py <<'PY'
import json
import unittest

from user import User


class UserTest(unittest.TestCase):
    def test_to_json_has_id_and_name(self):
        self.assertEqual(json.loads(User(1, 'Ada').to_json()), {'id': 1, 'name': 'Ada'})


if __name__ == '__main__':
    unittest.main()
PY
commit "Add user model"
echo "base=$(git rev-parse HEAD)"
