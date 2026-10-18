function claudes --description 'Run Claude Code at the git root, in a nono sandbox if the repo has a profile'
    if git rev-parse --git-dir >/dev/null 2>&1
        set -l git_root (git rev-parse --show-toplevel)
        set -l current_dir (pwd)

        if test "$git_root" != "$current_dir"
            cd "$git_root"
            echo "Navigated to git root: $git_root"
        end
    end

    set -l args
    set -l fork 0
    set -l has_resume 0
    for arg in $argv
        switch $arg
            case --fs
                set fork 1
            case -r --resume -c --continue
                set has_resume 1
                set -a args "$arg"
            case '*'
                set -a args "$arg"
        end
    end

    if test $fork -eq 1
        set -a args --fork-session

        # --fork-session only applies with --resume or --continue. A bare
        # session ID is otherwise sent to claude as a prompt, so make it the
        # value of --resume.
        if test $has_resume -eq 0
            for i in (seq (count $args))
                if string match -rq '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -- $args[$i]
                    set -l sid $args[$i]
                    set -e args[$i]
                    set args --resume $sid $args
                    break
                end
            end
        end
    end

    # With no slug, the launcher cannot find the repo profile. It must not start without a sandbox.
    set -l slug (~/.config/agents/bin/repo-slug.sh)
    if test -z "$slug"
        echo "claudes: repo-slug.sh printed no slug" >&2
        return 1
    end
    # Two lines make two profile paths, and `test -f` fails on them.
    if test (count $slug) -ne 1
        echo "claudes: repo-slug.sh printed more than one line" >&2
        return 1
    end
    set -l profile repo-$slug
    if test -f ~/.config/nono/profiles/$profile.json
        __claude_nono $profile $args
    else
        claude $args
    end
end

function __claude_nono --description 'Run claude in the nono sandbox of profile <name>'
    set -l profile $argv[1]
    set -l args $argv[2..-1]
    set -l profiles ~/.config/nono/profiles

    # A broken profile must stop the start. It must not fall back to no sandbox.
    set -l base (jq -er '.extends | strings' $profiles/$profile.json 2>/dev/null)
    or begin
        echo "claudes: $profiles/$profile.json has no \"extends\" string" >&2
        return 1
    end

    # No review list at exit: its rows default to grant, and claude-upgrade types into the pane.
    set -l nono_args --profile $profile --allow-cwd --suppress-save-prompt /
    if test -f $profiles/$base-local.json
        set -a nono_args --extends $base-local
    end

    # In a linked worktree, git writes to the .git directory of the main checkout.
    set -l git_dir (git rev-parse --path-format=absolute --git-dir)
    set -l common_dir (git rev-parse --path-format=absolute --git-common-dir)
    if test "$git_dir" != "$common_dir"
        set -a nono_args --allow $common_dir
    end

    # An adb server that starts inside the sandbox has no USB or LAN access.
    if type -q adb
        adb start-server >/dev/null 2>&1
    end

    # The sandbox can write only the ~/.ai directory of this repo.
    set -l ai_dir ~/.ai/(string replace -r '^repo-' '' -- $profile)
    mkdir -p $ai_dir
    set -a nono_args --allow $ai_dir

    # Sandboxed sessions have their own Claude Code config directory. The profile makes ~/.claude
    # read-only. Claude Code makes its lock directory next to the config directory, so both are
    # in one grant. The links give read-only access to the user files in ~/.claude.
    set -l sandbox_root ~/.claude-sandbox
    set -lx CLAUDE_CONFIG_DIR $sandbox_root/config
    mkdir -p $CLAUDE_CONFIG_DIR
    for item in CLAUDE.md agents commands keybindings.json output-styles plugins rules skills themes
        if not test -e $CLAUDE_CONFIG_DIR/$item; and not test -L $CLAUDE_CONFIG_DIR/$item
            ln -s ~/.claude/$item $CLAUDE_CONFIG_DIR/$item
        end
    end
    set -a nono_args --allow $sandbox_root
    # The settings of ~/.claude are the command-line layer. The user layer in the sandbox config
    # directory stays writable for /effort and /config.
    set -l settings_args --settings ~/.claude/settings.json

    # herdr-start-claude is a mediated command, and nono finds it on PATH.
    set -lx PATH ~/.config/agents/bin $PATH

    # One proxy port per session, so that parallel sessions do not collide. The port is below
    # 49152: the profile opens 49152-65535 to every sandbox for Gradle.
    set -l port (python3 -I -c '
import random, socket
for _ in range(10):
    port = random.randint(30000, 49151)
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", port))
    except OSError:
        continue
    finally:
        s.close()
    print(port)
    break')
    if test -z "$port"
        echo "claudes: found no free proxy port in 30000-49151" >&2
        return 1
    end
    set -a nono_args --proxy-port $port

    # A Gradle daemon keeps the sandbox and the proxy port of the session that started it, so
    # each session gets its own daemon registry. The sandbox cannot use Kotlin daemons.
    set -l registry $git_dir/nono-gradle-daemons/$fish_pid
    mkdir -p $registry
    set -lx JDK_JAVA_OPTIONS (string join ' ' -- \
        -Djava.net.preferIPv4Stack=true \
        -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=$port \
        -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=$port \
        '-Dhttp.nonProxyHosts=localhost|127.0.0.1' \
        "-Dorg.gradle.daemon.registry.base=\"$registry\"" \
        -Dorg.gradle.project.kotlin.compiler.execution.strategy=in-process)

    # Herdr sees nono, not claude, as the pane process. HERDR_AGENT tells Herdr to read the pane
    # as Claude Code.
    set -lx HERDR_AGENT claude
    # A spinner title makes Herdr show "working" until Claude sets its own title. Thus
    # `herdr agent start` waits for the Claude prompt and does not type into the nono banner.
    # The title goes to the terminal only, not into piped output. sh keeps the error quiet when
    # there is no terminal.
    if test "$HERDR_ENV" = 1
        sh -c 'printf "\033]2;%s\007" "$1" >/dev/tty' sh '⠿ nono sandbox starting' 2>/dev/null
    end

    nono run $nono_args -- claude $settings_args $args
    set -l code $status
    __claude_stop_daemons $registry
    rm -rf $registry
    return $code
end

function __claude_stop_daemons --description 'Stop the Gradle daemons of one session registry'
    # A daemon has the registry path in its JDK_JAVA_OPTIONS. ps -E shows the environment.
    # env -u keeps ps itself out of the match.
    for line in (env -u JDK_JAVA_OPTIONS ps -E -ww -x -o pid=,command=)
        if string match -q -- "*registry.base=\"$argv[1]\"*" $line
            kill (string trim -- $line | string split -f1 ' ')
        end
    end
end

function claude-config --description 'Edit the nono sandbox profile of this repo'
    set -l slug (~/.config/agents/bin/repo-slug.sh)
    if test "$slug" = _no-repo
        echo "claude-config: not in a git repo" >&2
        return 1
    end
    set -l file ~/.config/nono/profiles/repo-$slug.json
    if not test -f $file
        printf '%s\n' \
            '{' \
            '  "extends": "claude-android",' \
            "  \"meta\": { \"name\": \"repo-$slug\" }," \
            '  "filesystem": { "read": [] },' \
            '  "network": { "allow_domain": [] }' \
            '}' >$file
    end
    $EDITOR $file
    nono profile validate repo-$slug
end

function __claude_upgrade_available --description 'Print "current -> new" if a newer claude-code cask exists'
    # --greedy: the cask may be marked auto_updates, which outdated skips otherwise.
    # brew outdated exits 1 when the cask IS outdated, so only its output is usable.
    brew outdated --cask --greedy --verbose claude-code@latest
end

function __claude_upgrade_cask
    echo "Upgrading claude-code cask..."
    if not brew upgrade --cask claude-code@latest
        echo "claude-upgrade: brew upgrade failed" >&2
        return 1
    end
end

function __claude_plugin_versions --description 'Print "<id> <scope> <version>" for every installed plugin'
    claude plugin list --json | jq -r '.[] | "\(.id) \(.scope) \(.version)"'
end

function __claude_upgrade_plugins
    # Over SSH, each GitHub marketplace waits on the 1Password agent twice: probe and fetch.
    set -lx CLAUDE_CODE_PLUGIN_PREFER_HTTPS 1

    echo "Updating plugin marketplaces..."
    # One job per marketplace. Plugin updates stay sequential: each one rewrites
    # installed_plugins.json, and claude has no lock on it.
    sh -c '
        for name; do
            (claude plugin marketplace update "$name" >/dev/null ||
                echo "claude-upgrade: marketplace update failed: $name" >&2) &
        done
        wait' sh (claude plugin marketplace list --json | jq -r '.[].name')

    echo "Updating plugins..."
    for line in (claude plugin list --json | jq -r '.[] | select(.scope != "synced") | "\(.id) \(.scope)"')
        set -l parts (string split ' ' -- $line)
        claude plugin update $parts[1] --scope $parts[2]
        or echo "claude-upgrade: plugin update failed: $parts[1]" >&2
    end
end

# --- Multiplexer dispatch. Every tmux and herdr call lives in these nine helpers.
# --- The rest of claude-upgrade works the same under either one.

function __claude_mux --description 'Which multiplexer this shell is inside: herdr, tmux, or empty'
    if set -q HERDR_PANE_ID
        echo herdr
    else if set -q TMUX
        echo tmux
    end
end

function __claude_pane_map --description 'Emit "<shell_pid> <pane_target>" for every pane'
    switch $argv[1]
        case tmux
            tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}.#{pane_index}'
        case herdr
            # herdr has no global process listing, so this needs one call per
            # pane. shell_pid matches tmux's pane_pid, so the caller's ppid
            # lookup works unchanged.
            for p in (herdr pane list 2>/dev/null | jq -r '[.. | objects | .pane_id? // empty] | .[]')
                herdr pane process-info --pane $p 2>/dev/null \
                    | jq -r '[.. | objects | select(.shell_pid? != null and .pane_id? != null)
                              | "\(.shell_pid) \(.pane_id)"] | first // empty'
            end
    end
end

function __claude_pane_is_current --description 'Is <target> the pane this shell runs in?'
    switch $argv[1]
        case tmux
            test (tmux display-message -p -t $argv[2] '#{pane_id}') = "$TMUX_PANE"
        case herdr
            test "$argv[2]" = "$HERDR_PANE_ID"
    end
end

function __claude_pane_label --description 'Human-readable location for <target>'
    switch $argv[1]
        case tmux
            set -l parts (string split -m 1 ':' -- $argv[2])  # session name has no colon
            echo "$parts[1] • "(string replace '.' ':' -- $parts[2])
        case herdr
            echo $argv[2]
    end
end

function __claude_quit_pane --description 'Ask the claude in <target> to exit'
    switch $argv[1]
        case tmux
            tmux send-keys -t $argv[2] Escape
            tmux send-keys -t $argv[2] C-c
            tmux send-keys -t $argv[2] '/exit' Enter
        case herdr
            herdr pane send-keys $argv[2] esc >/dev/null
            herdr pane send-keys $argv[2] ctrl+c >/dev/null
            herdr pane run $argv[2] '/exit' >/dev/null
    end
end

function __claude_pane_tail --description 'Print the last lines of <target>'
    switch $argv[1]
        case tmux
            tmux capture-pane -p -t $argv[2] | tail -n 15
        case herdr
            herdr pane read $argv[2] --lines 15
    end
end

function __claude_pane_confirm --description 'Press Enter in <target>'
    switch $argv[1]
        case tmux
            tmux send-keys -t $argv[2] Enter
        case herdr
            herdr pane send-keys $argv[2] enter >/dev/null
    end
end

function __claude_resume_work --description 'Wait until the claude in <target> is idle, then ask it to continue its work'
    switch $argv[1]
        case tmux
            # tmux cannot see the agent state.
            return 1
        case herdr
            herdr agent wait $argv[2] --until idle --timeout 60000 >/dev/null
            and herdr agent prompt $argv[2] 'An upgrade restarted this session. It interrupted your turn or stopped your background tasks. Check the state of your work, then continue it and start the stopped tasks again.' >/dev/null
    end
end

function __claude_pane_send --description 'Run <cmd> in <target>'
    switch $argv[1]
        case tmux
            tmux send-keys -t $argv[2] $argv[3] Enter
        case herdr
            herdr pane run $argv[2] $argv[3] >/dev/null
    end
end

function claude-upgrade --description 'Upgrade the cask and plugins, quit interactive claude sessions, relaunch each resuming its conversation'
    set -l dry_run 0
    for arg in $argv
        switch $arg
            case --dry-run -n
                set dry_run 1
            case '*'
                echo "claude-upgrade: unknown argument: $arg" >&2
                return 2
        end
    end

    if not type -q jq
        echo "claude-upgrade: jq not found" >&2
        return 1
    end
    set -l mux (__claude_mux)
    if test -z "$mux"
        echo "claude-upgrade: not inside tmux or herdr" >&2
        return 1
    end

    echo "Checking for a new claude-code version..."
    set -l outdated (__claude_upgrade_available)
    if test -n "$outdated"
        echo "New version: $outdated"
    else
        echo "claude-code is up to date."
    end

    # Upgrade before quitting, so a failed upgrade leaves every session running.
    if test $dry_run -eq 0
        if test -n "$outdated"; and not __claude_upgrade_cask
            echo "claude-upgrade: not quitting sessions" >&2
            return 1
        end
        set -l plugins_before (__claude_plugin_versions)
        __claude_upgrade_plugins
        set -l plugins_after (__claude_plugin_versions)
        # No new cask and no new plugin: nothing to quit.
        if test -z "$outdated"; and test "$plugins_before" = "$plugins_after"
            echo "Already up to date."
            return 0
        end
    end

    # Map pane shell pid -> pane target, once.
    set -l pane_pids
    set -l pane_targets
    for line in (__claude_pane_map $mux)
        set -l parts (string split -m 1 ' ' -- $line)  # session names may contain spaces
        set -a pane_pids $parts[1]
        set -a pane_targets $parts[2]
    end

    # Discover sessions. Parallel arrays of fields for kept records.
    set -l rec_pid
    set -l rec_pane
    set -l rec_status
    set -l rec_name
    set -l rec_cwd
    set -l rec_sid
    set -l rec_file
    set -l skipped

    # Sandboxed sessions keep their session files in the sandbox config directory.
    for f in ~/.claude/sessions/*.json ~/.claude-sandbox/config/sessions/*.json
        test -f "$f"; or continue
        set -l fields (jq -r '[.pid, .sessionId, .cwd, .status, (.waitingFor // ""), (.name // ""), .kind] | @tsv' "$f" 2>/dev/null)
        test -n "$fields"; or continue
        set -l cols (string split \t -- $fields)
        set -l pid $cols[1]
        set -l sid $cols[2]
        set -l cwd $cols[3]
        set -l sess_status $cols[4]
        set -l waitingfor $cols[5]
        set -l name $cols[6]
        set -l kind $cols[7]

        # A sandboxed session can write these files. The session ID goes into a shell outside
        # the sandbox, and the name, the cwd, and the status go to the terminal.
        string match -rq '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' -- "$sid"; or continue
        string match -rq '^[0-9]+$' -- "$pid"; or continue
        set name (string replace -ra '[[:cntrl:]]' '' -- "$name")
        set cwd (string replace -ra '[[:cntrl:]]' '' -- "$cwd")
        set sess_status (string replace -ra '[[:cntrl:]]' '' -- "$sess_status")

        test "$kind" = interactive; or continue
        ps -p $pid >/dev/null 2>&1; or continue  # stale file, dead pid
        # A forged file can name the PID of another process.
        string match -rq '(^|/)claude$' -- (ps -o comm= -p $pid 2>/dev/null); or continue

        set -l ppid (string trim -- (ps -o ppid= -p $pid 2>/dev/null))
        # In a nono sandbox, the parent of claude is nono. The pane shell is the parent of nono.
        # nono prints its exit summary after claude exits, so the quit waits for nono.
        set -l wait_pid $pid
        set -l parent_command (ps -o comm= -p $ppid 2>/dev/null)
        if test -n "$parent_command"; and string match -q '*nono' -- $parent_command
            set wait_pid $ppid
            set ppid (string trim -- (ps -o ppid= -p $ppid 2>/dev/null))
        end
        test -n "$ppid"; or continue

        set -l target ""
        for i in (seq (count $pane_pids))
            if test "$pane_pids[$i]" = "$ppid"
                set target $pane_targets[$i]
                break
            end
        end

        set -l cwd_disp (string replace -- $HOME '~' $cwd)
        if test -z "$target"
            set -a skipped "$name ($cwd_disp): not in $mux"
            continue
        end

        # Never quit the controlling pane.
        if __claude_pane_is_current $mux $target
            set -a skipped "$name ($cwd_disp): controlling pane"
            continue
        end

        set -a rec_pid $wait_pid
        set -a rec_pane $target
        set -a rec_status $sess_status
        set -a rec_name $name
        set -a rec_cwd $cwd
        set -a rec_sid $sid
        set -a rec_file $f
    end

    set -l n (count $rec_pid)
    if test $n -eq 0
        echo "No claude sessions to relaunch."
        for s in $skipped
            echo "  skip: $s"
        end
        return 0
    end

    # List sessions: location line, then claude-info line with colored status.
    set -l sep ' • '
    echo "Discovered $n interactive claude session(s):"
    for i in (seq $n)
        set -l where (__claude_pane_label $mux $rec_pane[$i])
        set -l cwd (string replace -- $HOME '~' $rec_cwd[$i])
        set -l name $rec_name[$i]
        test -n "$name"; or set name '(unnamed)'

        set -l label
        set -l color
        switch $rec_status[$i]
            case idle
                set label IDLE
                set color green
            case busy
                set label BUSY
                set color red
            case waiting
                set label PROMPT
                set color red
            case '*'
                set label (string upper $rec_status[$i])
                set color yellow
        end

        echo "- $where"
        echo "  $name$sep$cwd$sep"(set_color $color)$label(set_color normal)
    end
    for s in $skipped
        echo "- skip: $s"
    end

    if test $dry_run -eq 1
        return 0
    end

    read -l -P "Quit these $n session(s) and relaunch? [y/N] " reply
    if not string match -rqi '^y(es)?$' -- $reply
        echo "Aborted."
        return 1
    end

    # Quit each gracefully, then wait for the pid to die.
    set -l quit_ok  # parallel index list into rec_* of successfully quit sessions
    set -l interrupted  # indexes into rec_* of sessions that the quit interrupted
    for i in (seq $n)
        set -l pane $rec_pane[$i]
        set -l pid $rec_pid[$i]
        # The status can change after discovery.
        switch (jq -r .status $rec_file[$i] 2>/dev/null)
            case busy waiting
                set -a interrupted $i
        end
        __claude_quit_pane $mux $pane

        set -l dead 0
        for t in (seq 30)  # ~15s at 0.5s
            if not ps -p $pid >/dev/null 2>&1
                set dead 1
                break
            end
            # A background task makes /exit ask for a confirmation. Option 1, "Exit and stop
            # tasks", is selected.
            if test $t -eq 4; and __claude_pane_tail $mux $pane | string match -q '*Background work is running*'
                contains -- $i $interrupted; or set -a interrupted $i
                __claude_pane_confirm $mux $pane
            end
            sleep 0.5
        end
        if test $dead -eq 1
            set -a quit_ok $i
        else
            echo "claude-upgrade: pane $pane (pid $pid) did not exit in 15s; skipping its relaunch" >&2
            __claude_pane_tail $mux $pane >&2
        end
    end

    # Relaunch each successfully-quit session, resuming its conversation.
    for i in $quit_ok
        __claude_pane_send $mux $rec_pane[$i] "claude --resume $rec_sid[$i]"
    end
    echo "Relaunched "(count $quit_ok)" session(s)."

    for i in $quit_ok
        contains -- $i $interrupted; or continue
        set -l where (__claude_pane_label $mux $rec_pane[$i])
        if __claude_resume_work $mux $rec_pane[$i]
            echo "Asked $where to continue its work."
        else
            echo "claude-upgrade: ask $where to continue its work" >&2
        end
    end
end
