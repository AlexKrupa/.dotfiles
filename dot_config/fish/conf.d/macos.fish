# macOS system admin dirs (diskutil, pmset, kextstat, etc.)
# Only login shells run path_helper, which adds these. tmux reuses a non-login
# shell's PATH across all panes, so add them explicitly. Append to keep them
# lower priority than Homebrew.
fish_add_path -a /usr/sbin /sbin
