# Generated: `git-spice shell completion fish`. Asks the binary at Tab time, so it stays current.
function __complete_git-spice
    set -lx COMP_LINE (commandline -cp)
    test -z (commandline -ct)
    and set COMP_LINE "$COMP_LINE "
    /opt/homebrew/bin/git-spice
end
complete -f -c git-spice -a "(__complete_git-spice)"
