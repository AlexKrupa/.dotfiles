#!/bin/sh
# Uses a fake plugin folder, so it touches no real watcher.
bin=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P)
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

# The fake watcher has a child process, like the `watchd follow` coprocess of a real watcher.
plugin() { # plugin <name>
  mkdir -p "$tmp/$1"
  cat >"$tmp/$1/watch.sh" <<EOF
#!/bin/sh
case \$1 in
  watch) sleep 600 & echo \$! >"$tmp/$1/child"; wait ;;
  ensure) nohup lockf -s -k -t 0 "$tmp/$1/lock" "\$0" watch >/dev/null 2>&1 & ;;
esac
EOF
  chmod +x "$tmp/$1/watch.sh"
}
watcher() { pgrep -f "$tmp/$1/watch.sh watch" | sort | tr '\n' ' '; } # watcher <name>
wait_for_child() { # wait_for_child <name>
  for _ in $(seq 50); do [ -s "$tmp/$1/child" ] && break; sleep 0.1; done
}
cleanup() { for name in running stopped; do pkill -f "$tmp/$name/watch.sh watch"; done; rm -rf "$tmp"; }
trap cleanup EXIT

plugin running
plugin stopped
"$tmp/running/watch.sh" ensure
wait_for_child running
old_watcher=$(watcher running)
old_child=$(cat "$tmp/running/child")
rm "$tmp/running/child"

"$bin/restart-watchers.sh" "$tmp/running" "$tmp/stopped"
wait_for_child running

check "a running watcher gets new processes" new \
  "$([ -n "$(watcher running)" ] && [ "$(watcher running)" != "$old_watcher" ] && echo new)"
check "the child of the old watcher stops" stopped \
  "$(kill -0 "$old_child" 2>/dev/null || echo stopped)"
check "a stopped watcher stays stopped" '' "$(watcher stopped)"

exit "$fail"
