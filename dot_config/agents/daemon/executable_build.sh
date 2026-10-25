#!/usr/bin/env bash
# Builds the watch daemon and installs it to ~/.local/bin/watchd. The rename makes sure that a
# running daemon keeps its old file, and sees a new inode.
set -euo pipefail

crate=$(cd "$(dirname "$0")" && pwd)
cargo build -q --release --locked --manifest-path "$crate/Cargo.toml"
mkdir -p "$HOME/.local/bin"
cp "$crate/target/release/watchd" "$HOME/.local/bin/.watchd.tmp"
mv "$HOME/.local/bin/.watchd.tmp" "$HOME/.local/bin/watchd"
