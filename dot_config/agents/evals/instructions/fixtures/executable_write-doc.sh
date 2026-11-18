#!/usr/bin/env bash
# Usage: write-doc.sh <repo-dir>
# docs/retry.md: 40 lines that say "3 retries" twice. No banned words, no dashes other than `-`,
# sentence-case headings, and no line over 100 characters. Prints `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
allow_commits

put docs/retry.md <<'MD'
# Retry behavior

The sync client sends each request to the sync server. A request can fail because of a network
error or a server error. The client then sends the request again.

## Default

The client makes 3 retries after the first failure. After the last retry, it reports the error to
the caller.

## Delays

The delay between two attempts grows with each attempt:

| Attempt | Delay |
| --- | --- |
| 1 | 1 second |
| 2 | 2 seconds |
| 3 | 4 seconds |

The client adds a random delay of up to 500 milliseconds to each delay. Then not all clients send
again at the same moment.

## Errors that get a retry

- Network errors, for example a closed connection
- HTTP 502, 503, and 504
- HTTP 429. The client waits for the time in the `Retry-After` header, if the header is there.

Other HTTP errors, for example 400 or 404, get no retry. The same request gives the same error.

## Configuration

Set `maxRetries` in `sync.json` to change the count. With 3 retries and the default delays, a
request can take up to 7 seconds before the client reports the error.

Set `maxRetries` to 0 for no retries.
MD
commit "Add retry docs"
echo "base=$(git rev-parse HEAD)"
