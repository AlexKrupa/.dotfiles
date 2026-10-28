# A local commit on main and a new commit in origin: main cannot fast-forward to origin/main.
commit "$repo" local.txt "Local change"
origin_commit main remote.txt "Remote change"
