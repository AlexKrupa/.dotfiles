function claude --description 'Run Claude Code after navigating to git root'
    if git rev-parse --git-dir >/dev/null 2>&1
        set git_root (git rev-parse --show-toplevel)
        set current_dir (pwd)

        if test "$git_root" != "$current_dir"
            cd "$git_root"
            echo "Navigated to git root: $git_root"
        end
    end

    command claude $argv
end

function __claude_upgrade_cask
    echo "Upgrading claude-code cask..."
    if not brew upgrade --cask claude-code@latest
        echo "claude-upgrade: brew upgrade failed" >&2
        return 1
    end
end

# --- Multiplexer dispatch. Every tmux and herdr call lives in these six helpers.
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

function __claude_pane_send --description 'Run <cmd> in <target>'
    switch $argv[1]
        case tmux
            tmux send-keys -t $argv[2] $argv[3] Enter
        case herdr
            herdr pane run $argv[2] $argv[3] >/dev/null
    end
end

function claude-upgrade --description 'Quit interactive claude sessions, upgrade the cask, relaunch each resuming its conversation'
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
    set -l skipped

    for f in ~/.claude/sessions/*.json
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

        test "$kind" = interactive; or continue
        ps -p $pid >/dev/null 2>&1; or continue  # stale file, dead pid

        set -l ppid (string trim -- (ps -o ppid= -p $pid 2>/dev/null))
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

        set -a rec_pid $pid
        set -a rec_pane $target
        set -a rec_status $sess_status
        set -a rec_name $name
        set -a rec_cwd $cwd
        set -a rec_sid $sid
    end

    set -l n (count $rec_pid)
    if test $n -eq 0
        echo "No claude sessions to quit; upgrading only."
        for s in $skipped
            echo "  skip: $s"
        end
        if test $dry_run -eq 1
            return 0
        end
        __claude_upgrade_cask
        return
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

    read -l -P "Quit these $n session(s), upgrade, relaunch? [y/N] " reply
    if not string match -rqi '^y(es)?$' -- $reply
        echo "Aborted."
        return 1
    end

    # Quit each gracefully, then wait for the pid to die.
    set -l quit_ok  # parallel index list into rec_* of successfully quit sessions
    for i in (seq $n)
        set -l pane $rec_pane[$i]
        set -l pid $rec_pid[$i]
        __claude_quit_pane $mux $pane

        set -l dead 0
        for t in (seq 30)  # ~15s at 0.5s
            if not ps -p $pid >/dev/null 2>&1
                set dead 1
                break
            end
            sleep 0.5
        end
        if test $dead -eq 1
            set -a quit_ok $i
        else
            echo "claude-upgrade: pane $pane (pid $pid) did not exit in 15s; skipping its relaunch" >&2
        end
    end

    # Upgrade. Abort relaunch on failure.
    if not __claude_upgrade_cask
        echo "claude-upgrade: not relaunching" >&2
        return 1
    end

    # Relaunch each successfully-quit session, resuming its conversation.
    for i in $quit_ok
        __claude_pane_send $mux $rec_pane[$i] "claude --resume $rec_sid[$i]"
    end
    echo "Relaunched "(count $quit_ok)" session(s)."
end
