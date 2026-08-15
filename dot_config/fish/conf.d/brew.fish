function __brew_quit_app --argument-names app_name --description 'Quit an app, force-kill if it ignores the quit'
    echo "Quitting $app_name..."
    osascript -e "tell application \"$app_name\" to quit" 2>/dev/null
    sleep 1
    # -i because the executable name often differs in case from the .app name (Handy/handy)
    if pgrep -xiq "$app_name"
        echo "Force-killing $app_name..."
        pkill -xi "$app_name" 2>/dev/null
        sleep 1
    end
end

function __brew_tagged_casks --argument-names tag --description 'Parse `cask:AppName:bundle.id` entries tagged in ~/.brewfile'
    for line in (grep "# $tag:" ~/.brewfile | grep -v '^#')
        set -l cask_name (string match -r 'cask "([^"]+)"' $line)[2]
        set -l metadata (string match -r "# $tag:\s*(.+)" $line)[2]
        if test -n "$cask_name" -a -n "$metadata"
            # `brew outdated` reports tap-qualified casks (user/tap/name) by bare name
            echo (path basename $cask_name):$metadata
        end
    end
end

function __brew_upgrade_cask --argument-names cask_name app_name bundle_id --description 'Upgrade a cask, quitting and restarting the app if it runs'
    if not pgrep -xiq "$app_name"
        HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask $cask_name
        return
    end

    __brew_quit_app $app_name
    HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask $cask_name
    echo "Restarting $app_name..."
    open -b "$bundle_id" -g
end

function __brew_release_notes --description 'Append a release notes URL to each `brew outdated --verbose` line read from stdin'
    # Homebrew has no repository field, so the URL is inferred from the download and homepage URLs
    python3 -c '
import json, re, subprocess, sys

lines = [line for line in sys.stdin.read().splitlines() if line.strip()]
if not lines:
    sys.exit()

try:
    info = json.loads(subprocess.run(
        ["brew", "info", "--json=v2", sys.argv[1]] + [line.split()[0] for line in lines],
        capture_output=True, text=True, check=True).stdout)
except (subprocess.CalledProcessError, json.JSONDecodeError):
    print("\n".join(lines))
    sys.exit()

TAGGED = re.compile(r"(https://github\.com/[^/]+/[^/]+)/releases/download/([^/]+)/")
REPO = re.compile(r"https://github\.com/[^/#?]+/[^/#?]+")

def release_url(pkg):
    urls = pkg.get("urls") or {}
    candidates = [url for url in (pkg.get("url"),
                                  (urls.get("stable") or {}).get("url"),
                                  (urls.get("head") or {}).get("url"),
                                  pkg.get("homepage")) if url]
    for candidate in candidates:
        tagged = TAGGED.match(candidate)
        if tagged:
            return tagged.group(1) + "/releases/tag/" + tagged.group(2)
    for candidate in candidates:
        repo = REPO.match(candidate)
        if repo:
            return re.sub(r"\.git$", "", repo.group(0)) + "/releases"
    return pkg.get("homepage") or ""

release_urls = {pkg.get("token") or pkg["name"]: release_url(pkg)
                for pkg in info["formulae"] + info["casks"]}

for line in lines:
    print((line + "  " + release_urls.get(line.split()[0], "")).rstrip())
' $argv
end

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
    # Tag casks in ~/.brewfile (prefix with ! to temporarily disable):
    #   restart-on-upgrade: AppName:bundle.id - auto quit/restart
    #   prompt-on-upgrade: AppName:bundle.id  - upgrade, prompt to restart if running
    #
    # --greedy compares Caskroom metadata, not the app on disk, so self-updating casks
    # (firefox, google-chrome) report as outdated on every run until brew reinstalls them.
    # Without a tty the prompts read empty and those casks are left outdated.

    set -l outdated_formulae (brew outdated --formula --verbose)
    set -l outdated_verbose (brew outdated --cask --greedy --verbose)
    set -l outdated_casks (string split ' ' -f1 -- $outdated_verbose)
    if test -z "$outdated_formulae" -a -z "$outdated_casks"
        brew cleanup
        return
    end

    set -l restart_entries
    for entry in (__brew_tagged_casks restart-on-upgrade)
        if contains -- (string split ':' $entry)[1] $outdated_casks
            set -a restart_entries $entry
        end
    end

    set -l prompt_entries
    for entry in (__brew_tagged_casks prompt-on-upgrade)
        if contains -- (string split ':' $entry)[1] $outdated_casks
            set -a prompt_entries $entry
        end
    end

    # Tagged casks are upgraded one at a time below, so keep them out of the bulk upgrade
    set -l tagged_casks (string replace -r ':.*' '' -- $restart_entries $prompt_entries)
    set -l bulk_casks
    for cask in $outdated_casks
        if not contains -- $cask $tagged_casks
            set -a bulk_casks $cask
        end
    end

    echo
    printf '%s\n' $outdated_formulae | __brew_release_notes --formula | sed 's/^/  /'
    printf '%s\n' $outdated_verbose | __brew_release_notes --cask | sed 's/^/  /'
    test -n "$bulk_casks"; and echo "  bulk:           $bulk_casks"
    test -n "$restart_entries"; and echo "  quit + restart: "(string join ' ' (string replace -r ':.*' '' -- $restart_entries))
    test -n "$prompt_entries"; and echo "  ask first:      "(string join ' ' (string replace -r ':.*' '' -- $prompt_entries))
    echo

    # Formulae need no app restart
    if test -n "$outdated_formulae"
        HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --formula
    end

    if test -z "$outdated_casks"
        brew cleanup
        return
    end

    if test -n "$bulk_casks"
        HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask $bulk_casks
    end

    for entry in $restart_entries
        __brew_upgrade_cask (string split ':' $entry)
    end

    # A cask upgrade force-quits a running app (via the cask's `uninstall quit:` directive),
    # so for running apps we must ask BEFORE upgrading.
    for entry in $prompt_entries
        set -l parts (string split ':' $entry)
        if pgrep -xiq "$parts[2]"
            read -l -P "$parts[1]: $parts[2] is running; upgrading will close it. Upgrade and restart now? [y/N] " confirm
            if not string match -riq '^y$' -- $confirm
                echo "Skipping $parts[1] (left outdated)."
                continue
            end
        end
        __brew_upgrade_cask $parts
    end

    brew cleanup
end

function brew-kill --description 'Remove Homebrew lock files'
  rm -rf $(brew --prefix)/var/homebrew/locks
end

# Verbatim output of `brew shellenv fish` (8 ms), inlined. Every value is a literal.
# Re-run and re-paste if the brew prefix ever moves off /opt/homebrew.
set --global --export HOMEBREW_PREFIX "/opt/homebrew";
set --global --export HOMEBREW_CELLAR "/opt/homebrew/Cellar";
set --global --export HOMEBREW_REPOSITORY "/opt/homebrew";
fish_add_path --global --move --path "/opt/homebrew/bin" "/opt/homebrew/sbin";
if test -n "$MANPATH[1]"; set --global --export MANPATH '' $MANPATH; end;
if not set --query INFOPATH; set INFOPATH ''; end; if not contains "/opt/homebrew/share/info" $INFOPATH; set --global --export INFOPATH "/opt/homebrew/share/info" $INFOPATH; end;
