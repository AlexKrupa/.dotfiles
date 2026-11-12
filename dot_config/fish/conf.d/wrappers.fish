# Wrappers hide the real binaries, so they go first. A parent process can pass a PATH that already
# has the folder at a later position, so `--move` is necessary.
fish_add_path -gP --move ~/.local/wrappers
