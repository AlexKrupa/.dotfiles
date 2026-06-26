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

function claude-upgrade --description 'Quit all interactive tmux claude sessions, upgrade the cask, relaunch each resuming its conversation'
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
    if not set -q TMUX
        echo "claude-upgrade: not inside tmux" >&2
        return 1
    end

    # Map tmux pane_pid -> pane target, once.
    set -l pane_pids
    set -l pane_targets
    for line in (tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}.#{pane_index}')
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

        if test -z "$target"
            set -a skipped "$name ($cwd): not in tmux, skipped"
            continue
        end

        # Never quit the controlling pane.
        set -l this_pane (tmux display-message -p -t $target '#{pane_id}')
        if test "$this_pane" = "$TMUX_PANE"
            set -a skipped "$name ($cwd): controlling pane, skipped"
            continue
        end

        set -l status_disp $sess_status
        test -n "$waitingfor"; and set status_disp "$sess_status/$waitingfor"

        set -a rec_pid $pid
        set -a rec_pane $target
        set -a rec_status $status_disp
        set -a rec_name $name
        set -a rec_cwd $cwd
        set -a rec_sid $sid
    end

    set -l n (count $rec_pid)
    if test $n -eq 0
        echo "claude-upgrade: no quittable interactive claude sessions found"
        for s in $skipped
            echo "  skip: $s"
        end
        return 0
    end

    # List table.
    echo "Discovered $n interactive claude session(s):"
    printf '%-20s %-26s %-34s %s\n' PANE STATUS NAME CWD
    for i in (seq $n)
        set -l warn ""
        if string match -rq '^(busy|waiting)' -- $rec_status[$i]
            set warn ' !'
        end
        printf '%-20s %-26s %-34s %s%s\n' $rec_pane[$i] $rec_status[$i] $rec_name[$i] $rec_cwd[$i] "$warn"
    end
    for s in $skipped
        echo "  skip: $s"
    end
    echo "  (! = busy/waiting, will be interrupted)"

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
        tmux send-keys -t $pane Escape
        tmux send-keys -t $pane C-c
        tmux send-keys -t $pane '/exit' Enter

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
    echo "Upgrading claude-code cask..."
    if not brew upgrade --cask claude-code@latest
        echo "claude-upgrade: brew upgrade failed; not relaunching" >&2
        return 1
    end

    # Relaunch each successfully-quit session, resuming its conversation.
    for i in $quit_ok
        tmux send-keys -t $rec_pane[$i] "claude --resume $rec_sid[$i]" Enter
    end
    echo "Relaunched "(count $quit_ok)" session(s)."
end
