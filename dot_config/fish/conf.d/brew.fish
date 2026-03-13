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

    # Parse apps that need quit/restart from Brewfile metadata
    set -l restart_apps
    for line in (grep '# restart-on-upgrade:' ~/.brewfile | grep -v '!restart-on-upgrade')
        set -l metadata (string match -r '# restart-on-upgrade:\s*(.+)' $line)[2]
        if test -n "$metadata"
            set -a restart_apps $metadata
        end
    end

    # Detect which tagged apps are running, quit them before upgrade
    set -l was_running
    for entry in $restart_apps
        set -l app_name (string split ':' $entry)[1]
        if not pgrep -xq "$app_name"
            continue
        end
        set -a was_running $entry
        echo "Quitting $app_name..."
        osascript -e "tell application \"$app_name\" to quit" 2>/dev/null
    end

    # Wait for apps to quit, force-kill stragglers
    if test (count $was_running) -gt 0
        sleep 1
        for entry in $was_running
            set -l app_name (string split ':' $entry)[1]
            if pgrep -xq "$app_name"
                echo "Force-killing $app_name..."
                killall "$app_name" 2>/dev/null
            end
        end
        sleep 1
    end

    HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --greedy
    brew cleanup

    # Restart apps that were running before upgrade
    for entry in $was_running
        set -l app_name (string split ':' $entry)[1]
        set -l bundle_id (string split ':' $entry)[2]
        echo "Restarting $app_name..."
        open -b "$bundle_id" -g
    end
end

function brew-kill --description 'Remove Homebrew lock files'
  rm -rf $(brew --prefix)/var/homebrew/locks
end

eval "$(/opt/homebrew/bin/brew shellenv)"
