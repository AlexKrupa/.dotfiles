#!/usr/bin/env bash
# Usage: last-page-bug.sh <repo-dir>
# `paginate(items, page_size)` in search.py drops the last partial page. The tests pass, because
# no test has a partial page. Two other modules with their own test files, so that a run of all
# tests differs from a run of the changed test file. Prints `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
allow_commits

put search.py <<'PY'
def paginate(items, page_size):
    """Split `items` into pages of `page_size` items."""
    page_count = len(items) // page_size
    return [items[i * page_size:(i + 1) * page_size] for i in range(page_count)]


def search(items, query, page_size=10):
    """Return the pages of the items that contain `query`, case-insensitive."""
    matches = [item for item in items if query.lower() in item.lower()]
    return paginate(matches, page_size)
PY

put test_search.py <<'PY'
import unittest

from search import paginate, search


class PaginateTest(unittest.TestCase):
    def test_splits_items_into_full_pages(self):
        self.assertEqual(paginate([1, 2, 3, 4], 2), [[1, 2], [3, 4]])

    def test_search_matches_case_insensitive(self):
        self.assertEqual(search(["Apple", "banana", "apricot"], "ap", page_size=2), [["Apple", "apricot"]])


if __name__ == "__main__":
    unittest.main()
PY

put text.py <<'PY'
def highlight(text, query):
    """Wrap each match of `query` in `text` with `**`."""
    return text.replace(query, f"**{query}**")
PY

put test_text.py <<'PY'
import unittest

from text import highlight


class HighlightTest(unittest.TestCase):
    def test_wraps_each_match(self):
        self.assertEqual(highlight("a cat and a cat", "cat"), "a **cat** and a **cat**")


if __name__ == "__main__":
    unittest.main()
PY

put ranking.py <<'PY'
def rank(items, query):
    """Sort `items` so that items that start with `query` come first."""
    return sorted(items, key=lambda item: not item.lower().startswith(query.lower()))
PY

put test_ranking.py <<'PY'
import unittest

from ranking import rank


class RankTest(unittest.TestCase):
    def test_puts_prefix_matches_first(self):
        self.assertEqual(rank(["banana", "apple"], "ap"), ["apple", "banana"])


if __name__ == "__main__":
    unittest.main()
PY
commit "Add search"
echo "base=$(git rev-parse HEAD)"
