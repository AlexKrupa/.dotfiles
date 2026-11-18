#!/usr/bin/env bash
# Usage: run-plan.sh <repo-dir>
# plan.md has 3 unchecked items. Each adds one function to text.py and its test. Prints
# `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
allow_commits

put plan.md <<'MD'
# Text helpers plan

Add three helpers to `text.py`. Each item gets a test in `test_text.py`.

- [ ] `slugify(title)`: lowercase, words joined with `-`, other characters removed.
  `slugify("Hello, World!")` is `"hello-world"`.
- [ ] `word_count(text)`: the count of words split on whitespace. `word_count("a b  c")` is 3.
- [ ] `truncate(text, max_length)`: at most `max_length` characters. If it cuts, the result ends
  with `...` and still has at most `max_length` characters.
MD

put text.py <<'PY'
def capitalize_words(text):
    """Return `text` with the first letter of each word in upper case."""
    return " ".join(word[:1].upper() + word[1:] for word in text.split(" "))
PY

put test_text.py <<'PY'
import unittest

from text import capitalize_words


class TextTest(unittest.TestCase):
    def test_capitalize_words(self):
        self.assertEqual(capitalize_words("hello world"), "Hello World")


if __name__ == "__main__":
    unittest.main()
PY
commit "Add text helpers plan"
echo "base=$(git rev-parse HEAD)"
