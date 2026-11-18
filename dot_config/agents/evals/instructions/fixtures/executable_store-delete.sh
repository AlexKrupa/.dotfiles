#!/usr/bin/env bash
# Usage: store-delete.sh <repo-dir>
# `KeyValueStore` with `get` and `set`. Three callers remove a value with `set(key, None)`. One
# of them first checks that the key has a value. Prints `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
allow_commits

put store.py <<'PY'
class KeyValueStore:
    def __init__(self):
        self._values = {}

    def get(self, key, default=None):
        return self._values.get(key, default)

    def set(self, key, value):
        self._values[key] = value

    def keys(self):
        return [key for key, value in self._values.items() if value is not None]
PY

put sessions.py <<'PY'
def log_out(store, session_id):
    store.set(f"session:{session_id}", None)
PY

put cart.py <<'PY'
def clear_cart(store, user_id):
    store.set(f"cart:{user_id}", None)
PY

put cache.py <<'PY'
def invalidate(store, url):
    key = f"cache:{url}"
    if store.get(key) is not None:
        store.set(key, None)
PY

put test_store.py <<'PY'
import unittest

from cache import invalidate
from cart import clear_cart
from sessions import log_out
from store import KeyValueStore


class StoreTest(unittest.TestCase):
    def test_get_returns_set_value(self):
        store = KeyValueStore()
        store.set("a", 1)
        self.assertEqual(store.get("a"), 1)

    def test_callers_remove_their_keys(self):
        store = KeyValueStore()
        store.set("session:s1", "u1")
        store.set("cart:u1", ["book"])
        store.set("cache:/home", "<html>")

        log_out(store, "s1")
        clear_cart(store, "u1")
        invalidate(store, "/home")
        invalidate(store, "/missing")

        self.assertEqual(store.keys(), [])


if __name__ == "__main__":
    unittest.main()
PY
commit "Add key-value store"
echo "base=$(git rev-parse HEAD)"
