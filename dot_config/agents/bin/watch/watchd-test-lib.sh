# shellcheck shell=bash
# Setup and helpers for the watchd tests. Source this file after `here` is set to this folder. It
# starts the fake session process and removes the temp folder at exit.
client="$here/watch.sh"
d=$(cd "$(mktemp -d)" && pwd -P) || exit 1
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# The events without the row number of the daemon. The row checks read $raw.
norow() { jq -c 'del(.row)' 2>/dev/null; }

# shellcheck source=watch-test-fakes.sh
source "$here/watch-test-fakes.sh"
export WATCH_BIN="$here"
# shellcheck source=watch-state.sh
source "$here/watch-state.sh"
wt=$(printf %s "$d/app" | shasum | cut -c1-12)

# Fake engine: prints and empties $D/events/<key>.jsonl. If $D/events/<key>.exit has lines, it
# removes the first line, prints $D/events/<key>.err on stderr, and exits with that line.
# If $D/events/<key>.state exists, it is the saved state of the engine.
# It adds its key and arguments to $D/args. If $D/events/<key>.sleep exists, it reads the events,
# then sleeps for that number of seconds, then prints the events.
mkdir -p "$d/events"
cat >"$d/bin/engine" <<'EOF'
#!/usr/bin/env bash
source "$WATCH_BIN/watch-state.sh"
echo "$*" >>"$D/args"
repo=. review=0 mrs=()
while (($#)); do
  case $1 in
    --repo) repo=$2; shift 2 ;;
    --review) review=1; shift ;;
    --mr) mrs+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done
key=$(watch_key "$repo" "$review" ${mrs[@]+"${mrs[@]}"})
f=$D/events/$key
if [ -f "$f.state" ]; then mkdir -p "$WATCH_ENGINE_DIR"; cp "$f.state" "$WATCH_ENGINE_DIR/$key.json"; fi
if [ -s "$f.exit" ]; then
  code=$(head -n1 "$f.exit")
  sed -i '' 1d "$f.exit"
  cat "$f.err" >&2 2>/dev/null
  exit "$code"
fi
out=$(cat "$f.jsonl" 2>/dev/null)
: >"$f.jsonl"
if [ -s "$f.sleep" ]; then
  seconds=$(cat "$f.sleep")
  rm -f "$f.sleep"
  sleep "$seconds"
fi
if [ -n "$out" ]; then printf '%s\n' "$out"; fi
EOF
chmod +x "$d/bin/engine"
export D="$d" WATCHD_ENGINE="$d/bin/engine" WATCHD_TICK=1 WATCH_CLIENT_TICK=1

sleep 600 &
session=$!
export WATCH_SESSION_PID=$session
daemon_pid() { cat "$WATCHD_DIR/daemon.pid" 2>/dev/null; }
is_daemon() { ps -o command= -p "$1" 2>/dev/null | grep -q 'watchd\.sh'; }
gone() { [ -e "$1" ] && echo no || echo yes; }
# Waits up to N seconds for a shell condition.
wait_for() {
  local n
  for n in $(seq $(($1 * 4))); do eval "$2" && return 0; sleep 0.25; done
  return 1
}
stop_daemon() {
  local pid
  pid=$(daemon_pid)
  if [ -n "$pid" ] && is_daemon "$pid"; then
    kill "$pid"
    wait_for 10 "! ps -p $pid >/dev/null"
  fi
}
reset() {
  stop_daemon
  rm -rf "$WATCHD_DIR" "$d/state/watch-gitlab" "$d/args"
  rm -f "$d/events/"*
}
trap 'stop_daemon; { kill "$session"; wait "$session"; } 2>/dev/null; rm -rf "$d"' EXIT

ev() { # kind iid
  jq -nc --arg k "$1" --argjson i "$2" \
    '{kind: $k, iid: $i, title: "Add foo", url: "u", actor: "anna", detail: "d", branch: "b"}'
}
events() { # key, lines
  printf '%s\n' "${@:2}" >>"$d/events/$1.jsonl"
}
# One client in the repo, with the arguments. Sets out, err, and code.
watch() {
  raw=$(cd "$d/app" && timeout 15 "$client" --interval 1 "$@" 2>"$d/err"); code=$?
  err=$(cat "$d/err")
  out=$(norow <<<"$raw")
}
sub="$WATCHD_DIR/subs/app.json"

# A client in the background. Its output goes to $d/NAME.out, its exit code to $d/NAME.code.
start() { # name, client arguments
  local name=$1
  shift
  rm -f "$d/$name.code"
  (cd "$d/app" && timeout 15 "$client" --interval 1 "$@" >"$d/$name.out" 2>"$d/$name.err"
    echo $? >"$d/$name.code") &
}
code_of() { # name: waits up to 10 seconds for the exit code
  wait_for 10 "[ -s '$d/$1.code' ]"
  cat "$d/$1.code" 2>/dev/null
}
client_is() { # pid of the client in the record
  jq -r .client_pid "$sub" 2>/dev/null
}
rounds_of() { cat "$WATCHD_DIR/rounds/$1" 2>/dev/null || echo 0; }
