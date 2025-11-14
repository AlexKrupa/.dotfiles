# Before this, set up a virtual env with uv
# uv venv ~/.local/py-tools-venv/
fish_add_path -P ~/.local/py-tools-venv/bin
fish_add_path ~/.local/bin

# Alternatively, use `python@<version> -m pip install --break-system-packages --user <dependency>
# when installing a library that no Python application depends on but is expected by, e.g., a tmux plugin or a script.

