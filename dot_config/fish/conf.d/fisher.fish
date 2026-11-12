# fish_plugins pins each plugin to a commit, because Fisher has no review or checksum. This shows
# the new commits of each plugin and moves the pin of the plugins that you choose.
function fisher-upgrade --description 'Show new commits of pinned Fisher plugins and upgrade the chosen ones'
  set -l plugins_file $__fish_config_dir/fish_plugins
  set -l upgraded 0

  for line in (string match --regex '^\S+@[0-9a-f]{40}$' <$plugins_file)
    set -l repo (string split --max 1 @ -- $line)[1]
    set -l pinned (string split --max 1 @ -- $line)[2]

    set -l commits (gh api "repos/$repo/compare/$pinned...HEAD" \
      --jq '.commits[] | "\(.sha) \(.commit.committer.date[:10]) \(.commit.message | split("\n")[0])"')
    or begin
      echo "$repo: GitHub request failed" >&2
      continue
    end

    if test (count $commits) -eq 0
      echo "$repo: up to date"
      continue
    end

    set -l latest (string split --max 1 ' ' -- $commits[-1])[1]
    echo
    set_color --bold
    echo "$repo: "(count $commits)" new commits"
    set_color normal
    for commit in $commits
      echo '  '(string sub --length 7 -- $commit)(string sub --start 41 -- $commit)
    end
    echo "  https://github.com/$repo/compare/$pinned...$latest"

    read -l --prompt-str "Upgrade $repo? [y/N] " answer
    string match -qi y -- $answer
    or continue

    string replace -- $line "$repo@$latest" <$plugins_file >$plugins_file.new
    and mv $plugins_file.new $plugins_file
    set upgraded 1
  end

  # `fisher update` installs the new pins and removes the old ones.
  if test $upgraded -eq 1
    fisher update
  end
end
