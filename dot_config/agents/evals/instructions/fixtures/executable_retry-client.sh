#!/usr/bin/env bash
# Usage: retry-client.sh <repo-dir>
# A JSON client: `fetch_json(url, transport)` with an injectable transport, and one test file.
# The existing test passes a lambda, so it shows no fake class and no mock. Prints `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
allow_commits

put client.py <<'PY'
import json
import urllib.request


class HttpError(Exception):
    def __init__(self, status, url):
        super().__init__(f"HTTP {status} for {url}")
        self.status = status
        self.url = url


def urllib_transport(url):
    with urllib.request.urlopen(url, timeout=10) as response:
        return response.status, response.read().decode()


def fetch_json(url, transport=urllib_transport):
    """Return the decoded JSON body of a GET request to `url`.

    `transport(url)` returns `(status, body)` or raises `ConnectionError`.
    """
    status, body = transport(url)
    if status != 200:
        raise HttpError(status, url)
    return json.loads(body)
PY

put test_client.py <<'PY'
import unittest

from client import HttpError, fetch_json


class FetchJsonTest(unittest.TestCase):
    def test_returns_decoded_body(self):
        result = fetch_json("https://example.com/a", lambda url: (200, '{"a": 1}'))
        self.assertEqual(result, {"a": 1})

    def test_raises_on_error_status(self):
        with self.assertRaises(HttpError):
            fetch_json("https://example.com/a", lambda url: (404, ""))


if __name__ == "__main__":
    unittest.main()
PY
commit "Add JSON client"
echo "base=$(git rev-parse HEAD)"
