function claude --description 'Run Claude Code after navigating to git root'
    if git rev-parse --git-dir >/dev/null 2>&1
        set git_root (git rev-parse --show-toplevel)
        set current_dir (pwd)

        if test "$git_root" != "$current_dir"
            cd "$git_root"
            echo "Navigated to git root: $git_root"
        end
    end

    command claude $argv
end
