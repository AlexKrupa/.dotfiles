# File name is fzf-utils.fish instead of fzf.fish to avoid conflict with fzf.fish plugin (https://github.com/PatrickF1/fzf.fish)

fzf_configure_bindings

bind -M insert ctrl-alt-b _fzf_search_git_branch
bind -M default ctrl-alt-b _fzf_search_git_branch

set -Ux FZF_DEFAULT_COMMAND "fd --type f --strip-cwd-prefix --hidden --follow --exclude .git"

# style: default, full, minimal
set -Ux FZF_DEFAULT_OPTS (printf '%s ' \
    '--style=minimal' \
    '--border' \
    # '--layout=reverse' \
    '--info=hidden' \
    | string collect)

