# Rex sets REX_BIN_DIR to the folder of its `rex` CLI. A login fish puts other folders first.
if set -q REX_BIN_DIR
  fish_add_path --path --prepend --move $REX_BIN_DIR
end
