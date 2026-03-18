function _fzf_search_git_branch --description "Search git branches and checkout the selected one"
    if not git rev-parse --git-dir >/dev/null 2>&1
        echo '_fzf_search_git_branch: Not in a git repository.' >&2
        return 1
    end

    set -f branch (
        git branch --all --color=always | \
        _fzf_wrapper --ansi \
            --prompt="Git Branch> " \
            --preview='git log --oneline --graph --color=always -20 {-1}' \
            $fzf_git_branch_opts
    )

    if test $status -eq 0
        # Strip leading whitespace, *, and remotes/origin/ prefix
        set -f branch (string trim -- $branch | string replace -r '^\* ' '' | string replace -r '^remotes/origin/' '')
        git checkout $branch
    end

    commandline --function repaint
end
