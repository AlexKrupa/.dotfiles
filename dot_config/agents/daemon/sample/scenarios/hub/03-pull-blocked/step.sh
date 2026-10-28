# A local commit on main and a new commit in origin: main cannot fast-forward to origin/main.
commit "$repo" local.txt "Local change"
git clone -q "$origin" "$SAMPLE_ROOT/clone"
commit "$SAMPLE_ROOT/clone" remote.txt "Remote change"
git -C "$SAMPLE_ROOT/clone" push -q origin main
rm -rf "$SAMPLE_ROOT/clone"
