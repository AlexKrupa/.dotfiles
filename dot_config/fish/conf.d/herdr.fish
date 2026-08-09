# Start herdr in interactive shells, replacing this shell.
#
# tmux autostart is off in tmux_utils.fish. To go back to tmux, set
# fish_tmux_autostart there back to true and delete this file.
#
# The guards match the tmux plugin's own, so herdr does not start inside a herdr
# pane, an editor terminal, or an IDE shell reader.
#
# conf.d loads alphabetically, so this exec happens before files sorting after
# it. herdr's own process misses the PATH entries those add. Panes are not
# affected, because each one runs a login fish that sources everything.

if status is-interactive
    and not set -q HERDR_PANE_ID
    and not set -q INSIDE_EMACS
    and not set -q VIM
    and not set -q NVIM
    and not set -q INTELLIJ_ENVIRONMENT_READER
    and not set -q VSCODE_RESOLVING_ENVIRONMENT
    and test "$TERM_PROGRAM" != vscode
    and test "$TERM_PROGRAM" != zed
    and test "$TERMINAL_EMULATOR" != JetBrains-JediTerm
    and command -v herdr >/dev/null
    exec herdr
end
