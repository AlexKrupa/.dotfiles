#!/usr/bin/env bash
# Install every plugin this config needs, and link the local ones. Safe to
# re-run: a plugin that is already there is skipped. Brew dependencies are not
# covered - install them first, see README.md "Setup".
set -euo pipefail
shopt -s nullglob

cd "$(dirname "${BASH_SOURCE[0]}")"

github_plugins=(
  fullerzz/herdr-plugin-sesh
  thanhdat77/herdr-navigator
  iurysza/termscope
  persiyanov/herdr-reviewr
  ChmaraX/herdr-nvim
)

local_plugins=(
  "$PWD/plugins/balance-panes"
  "$PWD/plugins/worktree-links"
  "$PWD/plugins/labels"
  "$PWD/plugins/caffeinate"
  "$PWD/plugins/nvim-sidebar-size-fix"
)

# A local clone of the herdr-pluck fork is for plugin development and for
# herdr-forks-sync. Without one, the fork installs from GitHub.
pluck_clone="$HOME/src/me/herdr-pluck"
if [[ -d $pluck_clone ]]; then
  local_plugins+=("$pluck_clone")
else
  github_plugins+=(AlexKrupa/herdr-pluck)
fi

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

# A plugin dropped from the lists above stays installed on other machines.
wanted_github=$(printf '%s\n' "${github_plugins[@]}" | jq -R . | jq -s .)
wanted_local=$(printf '%s\n' "${local_plugins[@]}" | jq -R . | jq -s .)
unwanted=$(herdr plugin list --json | jq -r --argjson gh "$wanted_github" --argjson local "$wanted_local" '
  .result.plugins[]
  | if .source.kind == "github" then
      select("\(.source.owner)/\(.source.repo)" as $s | $gh | any(. == $s) | not)
      | "uninstall \(.plugin_id)"
    else
      select(.plugin_root as $p | $local | any(. == $p) | not)
      | "unlink \(.plugin_id)"
    end')

if [[ -n $unwanted ]]; then
  echo
  echo "==> Plugins not in this config:"
  sed 's/^/    /' <<<"$unwanted"
  read -rp "Remove them? [y/N] " answer </dev/tty || answer=
  if [[ $answer == [yY] ]]; then
    while read -r command id; do
      herdr plugin "$command" "$id"
    done <<<"$unwanted"
  fi
fi

echo
herdr config check
herdr server reload-config
