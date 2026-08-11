# Rebase maintained forks of herdr plugins onto their upstreams.
# Reads forks.conf: fork, upstream, upstream ref, local clone.
# A conflict is only reported and skipped, never resolved automatically.
function herdr-forks-sync --description "Rebase forked herdr plugins onto upstream"
    set -l conf ~/.config/herdr/forks.conf
    test -f $conf; or return 0

    for raw in (cat $conf)
        set -l line (string trim -- $raw)
        test -z "$line"; and continue
        string match -q '#*' -- $line; and continue

        set -l cols (string split -n ' ' -- $line)
        test (count $cols) -eq 4
        or begin
            echo "==> skipping malformed line: $line"
            continue
        end
        set -l fork $cols[1]
        set -l upstream $cols[2]
        set -l ref $cols[3]
        set -l clone (string replace -r '^~' $HOME -- $cols[4])

        echo "==> $fork"
        if not test -d $clone/.git
            echo "    skipped: no clone at $clone"
            continue
        end
        if not git -C $clone remote get-url upstream >/dev/null 2>&1
            git -C $clone remote add upstream https://github.com/$upstream.git
        end
        set -l dirty (git -C $clone status --porcelain)
        if test -n "$dirty"
            echo "    skipped: $clone has uncommitted changes"
            continue
        end
        if not git -C $clone fetch --quiet upstream
            echo "    skipped: fetch from $upstream failed"
            continue
        end
        if git -C $clone rebase upstream/$ref
            git -C $clone push --quiet --force-with-lease
            or echo "    rebased, but push failed - push $clone by hand"
        else
            git -C $clone rebase --abort
            echo "    CONFLICT: rebase $clone onto upstream/$ref by hand, then push"
        end
    end
end

# Reinstall every GitHub-managed plugin at its latest commit. herdr has no
# `plugin update` in v1, so refreshing a plugin means reinstalling it. Pinned
# plugins keep their --ref, so this never silently unpins one. Afterwards it
# reports what moved, with links to the commits and the releases page.
function herdr-upgrade --description "Update all installed herdr plugins"
    herdr-forks-sync

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

if status is-interactive
    and command -v herdr >/dev/null
    herdr completion fish | source
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
