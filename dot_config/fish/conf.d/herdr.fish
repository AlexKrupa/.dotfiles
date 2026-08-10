# Reinstall every GitHub-managed plugin at its latest commit. herdr has no
# `plugin update` in v1, so refreshing a plugin means reinstalling it. Pinned
# plugins keep their --ref, so this never silently unpins one. Afterwards it
# reports what moved, with links to the commits and the releases page.
function herdr-upgrade --description "Update all installed herdr plugins"
    set -l before (mktemp)
    herdr plugin list --json >$before; or return 1

    for line in (jq -r '
            .result.plugins[]
            | select(.source.kind == "github")
            | [ ([.source.owner, .source.repo, (.source.subdir // empty)] | join("/")),
                (if .source.requested_ref then "--ref " + .source.requested_ref else empty end) ]
            | join(" ")' $before)
        echo "==> $line"
        herdr plugin install (string split " " -- $line) --yes
        or begin
            rm -f $before
            return 1
        end
    end

    echo
    herdr plugin list --json | jq -r --slurpfile old $before '
        ($old[0].result.plugins | map({key: .plugin_id, value: .}) | from_entries) as $o
        | .result.plugins[]
        | select(.source.kind == "github")
        | . as $n
        | $o[$n.plugin_id] as $b
        | "https://github.com/\($n.source.owner)/\($n.source.repo)" as $repo
        | if $b.source.resolved_commit == $n.source.resolved_commit then
            "  \($n.plugin_id) \($n.version) unchanged"
          else
            "  \($n.plugin_id) \($b.version // "none") -> \($n.version)",
            "    changes:  \($repo)/compare/\($b.source.resolved_commit)...\($n.source.resolved_commit)",
            "    releases: \($repo)/releases"
          end'
    rm -f $before
end

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
