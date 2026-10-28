#!/usr/bin/env bash
set -euo pipefail

# `cargo test` starts one test binary at a time. Each binary has its own test daemons, so this
# script starts all binaries at the same time. The arguments go to each binary, as a name filter.
crate=$(cd "$(dirname "$0")" && pwd)
logs=$(mktemp -d)
trap 'rm -rf "$logs"' EXIT

mapfile -t binaries < <(
  cargo test -q --locked --no-run --message-format=json --manifest-path "$crate/Cargo.toml" |
    jq -r 'select(.profile.test == true and .executable != null) | .executable'
)

cd "$crate"
pids=()
for binary in "${binaries[@]}"; do
  "$binary" -q "$@" >"$logs/$(basename "$binary")" 2>&1 &
  pids+=("$!")
done

failed=0
for index in "${!binaries[@]}"; do
  log="$logs/$(basename "${binaries[$index]}")"
  if wait "${pids[$index]}"; then
    echo "$(basename "${binaries[$index]}"): $(grep 'test result' "$log")"
  else
    failed=1
    cat "$log"
  fi
done
exit "$failed"
