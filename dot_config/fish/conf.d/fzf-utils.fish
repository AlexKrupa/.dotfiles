fzf_configure_bindings

set -Ux FZF_DEFAULT_COMMAND "fd --type f --strip-cwd-prefix --hidden --follow --exclude .git"

# style: default, full, minimal
set -Ux FZF_DEFAULT_OPTS (printf '%s ' \
    '--style=minimal' \
    '--border' \
    # '--layout=reverse' \
    '--info=hidden' \
    | string collect)

