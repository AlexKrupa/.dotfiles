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

    if not test -d $clone/.git
      echo "==> $fork skipped: no clone at $clone"
      continue
    end
    if not git -C $clone remote get-url upstream >/dev/null 2>&1
      git -C $clone remote add upstream https://github.com/$upstream.git
    end
    set -l dirty (git -C $clone status --porcelain)
    if test -n "$dirty"
      echo "==> $fork skipped: $clone has uncommitted changes"
      continue
    end
    if not git -C $clone fetch --quiet upstream
      echo "==> $fork skipped: fetch from $upstream failed"
      continue
    end
    set -l head (git -C $clone rev-parse HEAD)
    if git -C $clone rebase --quiet upstream/$ref
      git -C $clone push --quiet --force-with-lease
      or echo "==> $fork rebased, but push failed - push $clone by hand"
      # `plugin link` does not run build commands, thus rebuild the linked clone here.
      if test (git -C $clone rev-parse HEAD) != $head
        echo "==> $fork rebased onto $upstream, rebuilding"
        for cmd in (herdr plugin list --json | jq -c --arg p $clone '
            .result.plugins[] | select(.plugin_root == $p) | .build[]?.command')
          set -l output (sh -c 'cd "$1" && shift && exec "$@"' sh $clone (echo $cmd | jq -r '.[]') 2>&1)
          or begin
            printf '%s\n' $output
            echo "==> $fork build failed: "(echo $cmd | jq -r 'join(" ")')" - rebuild $clone by hand"
          end
        end
      end
    else
      git -C $clone rebase --abort
      echo "==> $fork CONFLICT: rebase $clone onto upstream/$ref by hand, then push"
    end
  end
end

# herdr v1 has no `plugin update`, thus a reinstall is the only way to update a plugin.
function herdr-upgrade --description "Update all installed herdr plugins"
  # Installs the plugins that this machine does not have yet.
  ~/.config/herdr/setup.sh; or return 1
  herdr-forks-sync

  set -l before (mktemp)
  herdr plugin list --json >$before; or return 1

  for row in (jq -r '
      .result.plugins[]
      | select(.source.kind == "github")
      | [ ([.source.owner, .source.repo, (.source.subdir // empty)] | join("/")),
          (.source.resolved_commit // ""),
          (.source.requested_ref // ""),
          "https://github.com/\(.source.owner)/\(.source.repo).git" ]
      | @tsv' $before)
    set -l cols (string split \t -- $row)
    set -l spec $cols[1]
    set -l installed $cols[2]
    set -l ref $cols[3]
    set -l url $cols[4]

    set -l target $ref
    test -z "$target"; and set target HEAD
    # ls-remote cannot resolve a raw commit, thus use the ref as it is.
    set -l remote (git ls-remote $url $target 2>/dev/null | head -n1 | string split -f1 \t)
    test -z "$remote"; and set remote $ref
    if test -n "$remote"; and test "$remote" = "$installed"
      continue
    end

    echo "==> upgrading $spec"
    set -l args $spec
    test -n "$ref"; and set -a args --ref $ref
    set -l output (herdr plugin install $args --yes 2>&1)
    or begin
      printf '%s\n' $output
      rm -f $before
      return 1
    end
  end

  # A new commit without a new version has no release, thus link the commit comparison.
  herdr plugin list --json | jq -r --slurpfile old $before '
    ($old[0].result.plugins | map({key: .plugin_id, value: .}) | from_entries) as $o
    | [ .result.plugins[]
        | select(.source.kind == "github")
        | {id: .plugin_id, new: ., old: $o[.plugin_id]} ] as $plugins
    | ( $plugins[]
        | select(.old.source.resolved_commit != .new.source.resolved_commit)
        | "https://github.com/\(.new.source.owner)/\(.new.source.repo)" as $repo
        | "  \(.id) \(.old.version // "none") -> \(.new.version)  "
          + if .old.version == .new.version then
              "\($repo)/compare/\(.old.source.resolved_commit)...\(.new.source.resolved_commit)"
            else
              "\($repo)/releases/tag/v\(.new.version)"
            end ),
      ( $plugins
        | map(select(.old.source.resolved_commit == .new.source.resolved_commit))
        | select(length > 0)
        | "  unchanged: " + (map("\(.id) \(.new.version)") | join(", ")) )'
  rm -f $before

  # `brew upgrade herdr` does not restart the running server.
  set -l server (herdr status server --json | string collect)
  if echo $server | jq -e .server_binary_stale >/dev/null
    echo
    echo "==> the server runs herdr "(echo $server | jq -r .version)", the binary is "(herdr --version | string split -f2 ' ')
    echo "    to restart: herdr server stop, then herdr. The stop ends every pane process."
  end
end

if status is-interactive
  and command -v herdr >/dev/null
  herdr completion fish | source
end

# To go back to tmux, set fish_tmux_autostart to true in tmux_utils.fish and
# delete this file.

# An app started from a herdr pane gives the pane's HERDR_* variables to the
# terminals that it opens.
if set -q HERDR_PANE_ID
  and not test -S "$HERDR_SOCKET_PATH"
  set -e (set -xn | string match 'HERDR_*')
end

# herdr does not get the PATH entries from conf.d files that sort after this one.
# Panes get them, because each pane runs a login fish.
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
