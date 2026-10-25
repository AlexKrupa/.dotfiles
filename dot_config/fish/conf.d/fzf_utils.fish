# File name is fzf_utils.fish instead of fzf.fish to avoid conflict with fzf.fish plugin (https://github.com/PatrickF1/fzf.fish)

bind -M insert ctrl-alt-b _fzf_search_git_branch
bind -M default ctrl-alt-b _fzf_search_git_branch

fzf_configure_bindings --history=

set -gx FZF_DEFAULT_COMMAND "fd --type f --strip-cwd-prefix --hidden --follow --exclude .git"

set -gx FZF_DEFAULT_OPTS (printf '%s ' \
    '--style=minimal' \
    '--border' \
    '--info=hidden' \
    | string collect)

