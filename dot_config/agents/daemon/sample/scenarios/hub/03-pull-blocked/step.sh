# A local commit and a new commit in origin block the fast-forward of main.
commit "$repo" local.txt "Local change"
origin_commit main remote.txt "Remote change"
