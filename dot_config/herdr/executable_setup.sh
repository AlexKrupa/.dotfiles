#!/usr/bin/env bash
# Install every plugin this config needs, and link the local ones. Safe to
# re-run: a plugin that is already there is skipped. Brew dependencies are not
# covered - install them first, see README.md "Setup".
set -euo pipefail
shopt -s nullglob

cd "$(dirname "${BASH_SOURCE[0]}")"

github_plugins=(
  plannotator/herdr-annotate
  fullerzz/herdr-plugin-sesh
  thanhdat77/herdr-navigator
  iurysza/termscope
  persiyanov/herdr-reviewr
)

# herdr-pluck is linked from the fork clone, not installed from GitHub, so
# herdr-forks-sync can rebase it. See README.md "Forked plugins".
local_plugins=(
  "$PWD/plugins/balance-panes"
  "$PWD/plugins/worktree-links"
  "$PWD/plugins/auto-label"
  "$PWD/plugins/caffeinate"
  "$HOME/src/me/herdr-pluck"
)

chmod +x bin/* bin/tests/*.sh plugins/*/*.sh plugins/*/tests/*.sh plugins/*/tests/mocks/*

installed=$(herdr plugin list --json)

for spec in "${github_plugins[@]}"; do
  if jq -e --arg s "$spec" '
      .result.plugins[]
      | select(.source.kind == "github")
      | select("\(.source.owner)/\(.source.repo)" == $s)' <<<"$installed" >/dev/null; then
    echo "==> $spec is installed"
  else
    echo "==> $spec"
    herdr plugin install "$spec" --yes
  fi
done

for path in "${local_plugins[@]}"; do
  name=$(basename "$path")
  if [[ ! -d $path ]]; then
    echo "==> $name SKIPPED: no directory at $path"
    continue
  fi
  if jq -e --arg p "$path" '.result.plugins[] | select(.plugin_root == $p)' <<<"$installed" >/dev/null; then
    echo "==> $name is linked"
  else
    echo "==> $name"
    herdr plugin link "$path"
  fi
done

echo
herdr config check
herdr server reload-config
