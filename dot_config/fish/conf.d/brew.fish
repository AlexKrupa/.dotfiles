function brew-update --description 'Update Homebrew and show outdated'
  brew update -q
  echo && brew outdated --greedy
end

function brew-upgrade --description 'Upgrade all packages, restart accessibility apps'
    # Some apps (e.g. AltTab, LinearMouse, BetterTouchTool) hook into accessibility or
    # input-monitoring APIs to intercept mouse/trackpad/keyboard events. If brew replaces
    # the binary while the app is running, macOS may revoke its permissions or the app may
    # crash - leaving input blocked or unresponsive until the app is relaunched.
    # To avoid this, we quit tagged apps before upgrading and restart them after.
    # Tag casks in ~/.brewfile with `# restart-on-upgrade: AppName:bundle.id`
    # (prefix with ! to temporarily disable).

    # Upgrade formulae first (no app restart needed)
    HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --formula

    # Parse apps that need quit/restart from Brewfile metadata
    set -l restart_apps
    for line in (grep '# restart-on-upgrade:' ~/.brewfile | grep -v '!restart-on-upgrade')
        set -l cask_name (string match -r 'cask "([^"]+)"' $line)[2]
        set -l metadata (string match -r '# restart-on-upgrade:\s*(.+)' $line)[2]
        if test -n "$metadata" -a -n "$cask_name"
            set -a restart_apps "$cask_name:$metadata"
        end
    end

    # Upgrade tagged casks one-by-one: quit -> upgrade -> restart
    for entry in $restart_apps
        set -l cask_name (string split ':' $entry)[1]
        set -l app_name (string split ':' $entry)[2]
        set -l bundle_id (string split ':' $entry)[3]

        if not pgrep -xq "$app_name"
            HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask $cask_name
            continue
        end

        echo "Quitting $app_name..."
        osascript -e "tell application \"$app_name\" to quit" 2>/dev/null
        sleep 1
        if pgrep -xq "$app_name"
            echo "Force-killing $app_name..."
            killall "$app_name" 2>/dev/null
            sleep 1
        end

        HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask $cask_name

        echo "Restarting $app_name..."
        open -b "$bundle_id" -g
    end

    # Upgrade remaining (non-tagged) casks
    HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask --greedy
    brew cleanup
end

function brew-kill --description 'Remove Homebrew lock files'
  rm -rf $(brew --prefix)/var/homebrew/locks
end

eval "$(/opt/homebrew/bin/brew shellenv)"
