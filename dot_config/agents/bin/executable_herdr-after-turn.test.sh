#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/herdr-after-turn.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake herdr: logs each call on one line, with "|" for newlines in the arguments.
# MOCK_WAIT_FAIL=1 makes `agent wait` fail. `agent get` gives the kind MOCK_KIND, default fake.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/herdr" <<'EOF'
#!/bin/sh
printf 'herdr %s' "$*" | tr '\n' '|' >>"$MOCK_LOG"; echo >>"$MOCK_LOG"
if [ "$1 $2" = "agent wait" ] && [ -n "${MOCK_WAIT_FAIL:-}" ]; then exit 1; fi
if [ "$1 $2" = "agent get" ]; then
  echo '{"result":{"agent":{"agent":"'"${MOCK_KIND-fake}"'"}}}'; exit 0
fi
echo '{}'
EOF
chmod +x "$tmp/bin/herdr"

# Fake adapters. fake prints "FAKE <action> <argument>" and has no model action. other has the
# kind other.
mkdir -p "$tmp/integrations/fake" "$tmp/integrations/other"
cat >"$tmp/integrations/fake/agent.sh" <<'EOF'
#!/bin/sh
case $1 in
  kind) echo fake ;;
  model) echo "fake: no model action" >&2; exit 3 ;;
  *) echo "FAKE $1 $2" ;;
esac
EOF
cat >"$tmp/integrations/other/agent.sh" <<'EOF'
#!/bin/sh
case $1 in
  kind) echo other ;;
  *) echo "OTHER $1 $2" ;;
esac
EOF
chmod +x "$tmp/integrations/fake/agent.sh" "$tmp/integrations/other/agent.sh"
export PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/calls.log" HERDR_AFTER_TURN_SLEEP=0 \
  AGENT_INTEGRATIONS="$tmp/integrations"
wait_call="herdr agent wait wL:p1 --until idle --until done --timeout 600000"

: >"$MOCK_LOG"
printf '%s' $'ABC-2\n\nFix `x` in "$HOME"' | "$script" wL:p1 --clear ABC-1/old >/dev/null 2>&1
code=$?
check "clear: exit 0" 0 "$code"
check "clear: calls in order" \
  "herdr agent get wL:p1
$wait_call
herdr agent prompt wL:p1 FAKE clear ABC-1/old
herdr agent prompt wL:p1 ABC-2||Fix \`x\` in \"\$HOME\"" \
  "$(cat "$MOCK_LOG")"

: >"$MOCK_LOG"
"$script" wL:p1 --clear old 'effort medium' 'rename [ABC-2] Fix `x` for $HOME' <<<"/plan x" \
  >/dev/null 2>&1; code=$?
check "clear and actions: exit 0" 0 "$code"
check "clear and actions: adapter text after the clear, before the prompt" \
  "herdr agent get wL:p1
$wait_call
herdr agent prompt wL:p1 FAKE clear old
herdr agent prompt wL:p1 FAKE effort medium
herdr agent prompt wL:p1 FAKE rename [ABC-2] Fix \`x\` for \$HOME
herdr agent prompt wL:p1 /plan x" \
  "$(cat "$MOCK_LOG")"

: >"$MOCK_LOG"
"$script" wL:p1 'effort high' <<<"/plan x" >/dev/null 2>&1; code=$?
check "no clear: exit 0" 0 "$code"
check "no clear: actions, then the prompt" \
  "herdr agent get wL:p1
$wait_call
herdr agent prompt wL:p1 FAKE effort high
herdr agent prompt wL:p1 /plan x" \
  "$(cat "$MOCK_LOG")"

: >"$MOCK_LOG"
MOCK_KIND=other "$script" wL:p1 'effort high' <<<"p" >/dev/null 2>&1; code=$?
check "other kind: exit 0" 0 "$code"
check "other kind: the adapter of that kind" "herdr agent prompt wL:p1 OTHER effort high" \
  "$(grep 'OTHER' "$MOCK_LOG")"

: >"$MOCK_LOG"
"$script" wL:p1 --clear <<<"p" >/dev/null 2>&1; code=$?
check "--clear with no name: exit 1" 1 "$code"
check "--clear with no name: no herdr call" "" "$(cat "$MOCK_LOG")"

: >"$MOCK_LOG"
MOCK_WAIT_FAIL=1 "$script" wL:p1 --clear ABC-1/old <<<"p" >/dev/null 2>&1; code=$?
check "wait fails: exit 1" 1 "$code"
check "wait fails: no prompt" "" "$(grep 'agent prompt' "$MOCK_LOG")"

: >"$MOCK_LOG"
"$script" wL:p1 'rename [ABC-2] Fix x' </dev/null >/dev/null 2>&1; code=$?
check "actions, no prompt: exit 0" 0 "$code"
check "actions, no prompt: only the actions" \
  "herdr agent get wL:p1
$wait_call
herdr agent prompt wL:p1 FAKE rename [ABC-2] Fix x" \
  "$(cat "$MOCK_LOG")"

: >"$MOCK_LOG"
"$script" wL:p1 'rename -x y' </dev/null >/dev/null 2>&1; code=$?
check "title with a leading -: exit 0" 0 "$code"
check "title with a leading -: one adapter argument" "herdr agent prompt wL:p1 FAKE rename -x y" \
  "$(grep 'agent prompt' "$MOCK_LOG")"

: >"$MOCK_LOG"
"$script" wL:p1 --clear ABC-1/old </dev/null >/dev/null 2>&1; code=$?
check "no prompt text and no action: exit 1" 1 "$code"
check "no prompt text and no action: no herdr call" "" "$(cat "$MOCK_LOG")"

: >"$MOCK_LOG"
err=$(MOCK_KIND=none "$script" wL:p1 'effort high' <<<"p" 2>&1 >/dev/null); code=$?
check "unknown kind: exit 1" 1 "$code"
check "unknown kind: error" "herdr-after-turn: no agent integration for herdr kind 'none'" "$err"
check "unknown kind: no wait and no prompt" "" "$(grep -e 'agent wait' -e 'agent prompt' "$MOCK_LOG")"

: >"$MOCK_LOG"
err=$(MOCK_KIND= "$script" wL:p1 'effort high' <<<"p" 2>&1 >/dev/null); code=$?
check "no agent: exit 1" 1 "$code"
check "no agent: error" "herdr-after-turn: no agent in pane wL:p1" "$err"
check "no agent: no wait" "" "$(grep 'agent wait' "$MOCK_LOG")"

: >"$MOCK_LOG"
err=$("$script" wL:p1 --clear old 'effort high' 'model opus' <<<"p" 2>&1 >/dev/null); code=$?
check "adapter has no action: exit 1" 1 "$code"
check "adapter has no action: adapter error" "herdr-after-turn: fake: no model action" "$err"
check "adapter has no action: no wait and no prompt" "" \
  "$(grep -e 'agent wait' -e 'agent prompt' "$MOCK_LOG")"

exit $fail
