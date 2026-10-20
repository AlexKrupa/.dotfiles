# Sleep, wake, and network rules for the watch scripts. Source this file.
# The caller declares sleeper='' and kills $sleeper in its EXIT trap. The caller sets WATCH_HOST
# before the first nap. An empty WATCH_HOST (a local remote) skips the network probe.
# The caller defines exit_if_orphaned: it exits when no session can use the events of the watch.

# In the background: bash runs the TERM trap only after a foreground command ends.
bg_sleep() {
  sleep "$1" &
  sleeper=$!
  wait "$sleeper"
  sleeper=''
}

# True during full wake. A maintenance wake during system sleep has no Graphics capability.
full_wake() {
  pmset -g systemstate | grep -q Graphics
}

# Prints the host of an https://, ssh://, or git@host: URL. Prints nothing for a local path.
remote_host() {
  sed -nE 's#^[a-z+]+://([^@/]*@)?([^:/]+).*#\2#p; s#^[^@/:]+@([^:]+):.*#\1#p' <<<"$1"
}

is_network_error() {
  local re='no such host|dial tcp|i/o timeout|TLS handshake timeout|Could not resolve host'
  re+='|Failed to connect|[Cc]onnection refused|connection reset|timed out'
  re+='|[Nn]etwork is unreachable|HTTP 50[234]'
  [[ $1 =~ $re ]]
}

# One try: full wake, and the host accepts a connection on port 443.
online() {
  full_wake && { [[ -z $1 ]] || nc -z -G 5 "$1" 443 >/dev/null 2>&1; }
}

wait_online() {
  until online "$1"; do bg_sleep 10; exit_if_orphaned; done
}

# Waits for N seconds of awake time. A clock jump of more than the step plus 30 seconds is a
# system sleep. After a sleep, or with no full wake, it waits for the network and returns at once.
nap() {
  local left=$1 step start
  while ((left > 0)); do
    step=$((left < 10 ? left : 10))
    start=$(date +%s)
    bg_sleep "$step"
    if (($(date +%s) - start > step + 30)) || ! full_wake; then
      wait_online "$WATCH_HOST"
      return 0
    fi
    left=$((left - step))
  done
}
