#!/usr/bin/env bash
# Usage: why-question.sh <repo-dir>
# A task app with store.json and NOTES.md, which records the earlier recommendation of SQLite over
# a JSON file because of concurrent writes. Prints `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
allow_commits

put store.json <<'JSON'
{"tasks": [{"id": 1, "title": "Write the release notes", "done": false}]}
JSON

put NOTES.md <<'MD'
# Notes

- The task store moves from `store.json` to SQLite.
- Reason: the web workers and the cron job write tasks at the same time.
- A JSON file loses writes when two processes write it at once.
MD
commit "Add task store notes"
echo "base=$(git rev-parse HEAD)"
