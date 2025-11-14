# Remove duplicates from $PATH and $fish_user_paths
function dedup-paths
  # Remove duplicates from $PATH
  set -l unique_path
  for path in $PATH
    if not contains $path $unique_path
      set unique_path $unique_path $path
    end
  end
  set -gx PATH $unique_path

  # Remove duplicates from $fish_user_paths
  set -l unique_fish_user_paths
  for path in $fish_user_paths
    if not contains $path $unique_fish_user_paths
      set unique_fish_user_paths $unique_fish_user_paths $path
    end
  end
  set -U fish_user_paths $unique_fish_user_paths
end

