#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/install.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# The fake claude answers `plugin list --json` from $FIXTURE and logs the other calls. With
# FAKE_HEAL set, `plugin install` copies the source folder over the install path.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'FAKE'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "plugin list --json" ]; then cat "$FIXTURE"; exit 0; fi
echo "$*" >>"$FAKE_LOG"
if [ "$1 $2" = "plugin install" ] && [ -n "${FAKE_HEAL-}" ]; then
  rm -rf "$COPY" && cp -R "$SOURCE" "$COPY"
fi
FAKE
chmod +x "$tmp/bin/claude"

source_dir="$tmp/plugin-source"
marketplace="$tmp/marketplace"
export CLAUDE_CONFIG_DIR="$tmp/config" FIXTURE="$tmp/fixture.json" FAKE_LOG="$tmp/calls.log"
export SOURCE="$source_dir" COPY="$tmp/cache/watchd"
export PATH="$tmp/bin:$PATH"

# setup: a directory marketplace whose plugin watchd is a symlink to the source folder, and a
# user config that enables it.
mkdir -p "$source_dir/hooks" "$marketplace/.claude-plugin" "$CLAUDE_CONFIG_DIR"
echo '{"hooks":{}}' >"$source_dir/hooks/hooks.json"
ln -s "$source_dir" "$marketplace/watchd"
cat >"$marketplace/.claude-plugin/marketplace.json" <<JSON
{"name":"local-pins","plugins":[{"name":"watchd","source":"./watchd"}]}
JSON
cat >"$CLAUDE_CONFIG_DIR/settings.json" <<JSON
{
  "extraKnownMarketplaces": {"local-pins": {"source": {"source": "directory", "path": "$marketplace"}}},
  "enabledPlugins": {"watchd@local-pins": true}
}
JSON

# run <install path>: lists watchd at the install path, runs install.sh, sets code and out.
run() {
  jq -n --arg path "$1" \
    '[{id: "watchd@local-pins", scope: "user", installPath: $path}]' >"$FIXTURE"
  : >"$FAKE_LOG"
  out=$("$script" 2>&1); code=$?
}

# The plugin line of the output, with the column padding squeezed.
plugin_line() { grep '^plugins/' <<<"$out" | tr -s ' '; }

fresh_copy() {
  rm -rf "$COPY"
  mkdir -p "$(dirname "$COPY")"
  cp -R "$source_dir" "$COPY"
}

fresh_copy
echo '{"hooks":{"old":[]}}' >"$COPY/hooks/hooks.json"
run "$COPY"
check "a cache copy that differs from the source: exit 1" 1 "$code"
check "a cache copy that differs from the source: STALE line" \
  "plugins/watchd@local-pins STALE -> $COPY" "$(plugin_line)"
check "a cache copy that differs from the source: one reinstall" \
  $'plugin uninstall watchd@local-pins --scope user\nplugin install watchd@local-pins --scope user' \
  "$(grep '^plugin \(un\)\?install' "$FAKE_LOG")"

fresh_copy
run "$COPY"
check "a cache copy equal to the source: exit 0" 0 "$code"
check "a cache copy equal to the source: installed" \
  "plugins/watchd@local-pins installed" "$(plugin_line)"
check "a cache copy equal to the source: no reinstall" "" \
  "$(grep '^plugin \(un\)\?install' "$FAKE_LOG")"

run "$source_dir"
check "an install path that is the source folder: exit 0" 0 "$code"
check "an install path that is the source folder: installed" \
  "plugins/watchd@local-pins installed" "$(plugin_line)"
check "an install path that is the source folder: no reinstall" "" \
  "$(grep '^plugin \(un\)\?install' "$FAKE_LOG")"

fresh_copy
echo '{"hooks":{"old":[]}}' >"$COPY/hooks/hooks.json"
FAKE_HEAL=1 run "$COPY"
check "a differing copy that the reinstall fixes: exit 0" 0 "$code"
check "a differing copy that the reinstall fixes: installed" \
  "plugins/watchd@local-pins installed" "$(plugin_line)"

exit $fail
