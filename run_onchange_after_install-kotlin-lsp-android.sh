#!/bin/sh
# Builds the `kotlin-lsp` proxy of kotlin-lsp-android at a pinned commit. The proxy replaces the
# Homebrew `kotlin-lsp` for all LSP clients, because ~/.local/wrappers is first on PATH.
set -eu

commit=95dfbd67b3b7fb6a32b2ba0b2a07af91529fc0cc
repository="$HOME/src/kotlin-lsp-android"
output="$HOME/.local/wrappers/kotlin-lsp"

if [ ! -d "$repository/.git" ]; then
  echo "kotlin-lsp-android: $repository not found, skipped"
  exit 0
fi

if ! command -v go >/dev/null; then
  echo "kotlin-lsp-android: go not on PATH, skipped"
  exit 0
fi

# The build reads the commit from an archive. A checkout would change the files of the repository.
source_dir=$(mktemp -d)
mkdir -p "$(dirname "$output")"
temporary_output=$(mktemp "$output.XXXXXX")
trap 'rm -rf "$source_dir" "$temporary_output"' EXIT

git -C "$repository" archive "$commit" | tar -x -C "$source_dir"

(cd "$source_dir" && go build -trimpath -o "$temporary_output" ./cmd/kotlin-lsp-android)

# A running proxy keeps its old file. `mv` replaces the path in one step.
chmod 755 "$temporary_output"
mv "$temporary_output" "$output"
echo "kotlin-lsp-android: built $commit"
