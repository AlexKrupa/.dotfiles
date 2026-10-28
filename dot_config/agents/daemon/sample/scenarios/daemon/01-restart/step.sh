# A new test binary while an agent session waits: the daemon calls exec and keeps its PID, and the
# client of the agent connects again.
open_branch
agent start branch
pid=$(cat "$SAMPLE_STATE/watchd/daemon.pid")
starts() { grep -c "daemon start $pid\$" "$SAMPLE_STATE/watchd/watchd.log"; }
before=$(starts)
"$sample_dir/sample" start >/dev/null
restarted() { [ "$(starts)" -gt "$before" ]; }
wait_until "a new daemon start line with PID $pid" restarted
wait_until "the agent record of the branch is live again" agent_live branch
