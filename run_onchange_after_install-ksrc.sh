#!/bin/sh
# Builds ksrc from the fork at a reviewed commit (v0.7.0). Before you change the commit, review the
# diff: `--rg-args` passes any flag to `rg`, so agents use `ksrc mcp`, which has an allowlist.
# `ksrc clean --yes` deletes folders, so ~/.claude/settings.json denies `Bash(ksrc clean*)`.
set -eu

repository=https://github.com/AlexKrupa/ksrc.git
commit=8af86bc1f72db9e3afce7c11b13dbae7fde69bd0
checkout_dir="$HOME/.local/share/ksrc"

# Exit 1, not 0: chezmoi does not run a successful run_onchange script again, so a skip would
# leave ksrc unbuilt after Go is installed.
if ! command -v go >/dev/null; then
  echo "ksrc: go not on PATH. Run ~/.brew.sh, then chezmoi apply" >&2
  exit 1
fi

if [ ! -d "$checkout_dir/.git" ]; then
  git clone --quiet "$repository" "$checkout_dir"
fi
git -C "$checkout_dir" fetch --quiet origin "$commit"
git -C "$checkout_dir" -c advice.detachedHead=false checkout --quiet "$commit"

cd "$checkout_dir"
go build -trimpath -ldflags "-X github.com/respawn-llc/ksrc/internal/cli.Version=$commit" \
  -o "$HOME/.local/bin/ksrc" ./cmd/ksrc
echo "ksrc: built $commit"
