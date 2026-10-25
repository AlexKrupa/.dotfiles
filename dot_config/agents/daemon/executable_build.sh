#!/usr/bin/env bash
set -euo pipefail

crate=$(cd "$(dirname "$0")" && pwd)
cargo build -q --release --locked --manifest-path "$crate/Cargo.toml"
mkdir -p "$HOME/.local/bin"
# The rename keeps the old file of a running daemon, and the daemon sees a new inode.
cp "$crate/target/release/watchd" "$HOME/.local/bin/.watchd.tmp"
mv "$HOME/.local/bin/.watchd.tmp" "$HOME/.local/bin/watchd"
