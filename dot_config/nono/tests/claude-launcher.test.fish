# Tests for the claude launcher in ~/.config/fish/conf.d/claude.fish.
# Stubs nono, adb, and the claude binary. Usage: fish ~/.config/nono/tests/claude-launcher.test.fish
source ~/.config/fish/conf.d/claude.fish

set -g failures 0
function check --argument-names name
    if test $status -ne 0
        echo "FAIL: $name"
        set failures (math $failures + 1)
    else
        echo "ok: $name"
    end
end

set -g tmp (realpath (mktemp -d))
set -g log $tmp/calls.log
set -g profiles ~/.config/nono/profiles

# Stubs
function nono
    echo "nono $argv" >>$log
    echo "JDK_JAVA_OPTIONS=$JDK_JAVA_OPTIONS" >>$log
    echo "HERDR_AGENT=$HERDR_AGENT" >>$log
    echo "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR" >>$log
    echo "PATH1=$PATH[1]" >>$log
end
function adb; echo "adb $argv" >>$log; end
mkdir -p $tmp/bin
printf '#!/bin/sh\necho "claude-binary $*" >>%s\n' $log >$tmp/bin/claude
chmod +x $tmp/bin/claude
set -gx PATH $tmp/bin $PATH
set -e HERDR_ENV
# A global value hides the universal value of the user, and the test does not change it.
set -g claude_sandbox on

function new_repo --argument-names dir
    mkdir -p $dir
    git -C $dir init -q
    git -C $dir -c commit.gpgsign=false commit -q --allow-empty -m init
end

# Case 1: no repo file -> unsandboxed claude, no nono call
new_repo "$tmp/plain-repo-x1"
cd "$tmp/plain-repo-x1"
rm -f $log
claude --version
grep -q '^claude-binary --version$' $log; and not grep -q '^nono' $log
check "no repo file runs claude without nono"

# Case 2: repo file -> nono with profile, proxy port, registry, Kotlin in-process
new_repo "$tmp/sbx-test-repo"
echo '{"extends":"claude-android","meta":{"name":"repo-sbx-test-repo"}}' >$profiles/repo-sbx-test-repo.json
cd "$tmp/sbx-test-repo"
rm -f $log
claude --version
grep -q -- '--profile repo-sbx-test-repo' $log
check "repo file selects profile"
grep -q -- '--suppress-save-prompt / ' $log
check "exit review list is suppressed"
set -l port (string match -r -g -- '--proxy-port ([0-9]+) ' <$log)
test -n "$port"; and test $port -ge 30000; and test $port -le 49151
check "proxy port is set, in 30000-49151"
grep -q -E -- '-Dhttps.proxyPort=[0-9]+' $log
check "JVM proxy port is set"
grep -q -- 'nono-gradle-daemons' $log
check "daemon registry is set"
grep -q -- '-Dorg.gradle.project.kotlin.compiler.execution.strategy=in-process' $log
check "Kotlin in-process is set"
grep -q -- "-- claude --settings $HOME/.claude/settings.json --version" $log
check "claude gets the ~/.claude settings layer, then the args"
grep -q '^adb start-server' $log
check "adb server starts outside the sandbox"
not grep -q '^claude-binary' $log
check "no unsandboxed claude"
not grep -q -- "--allow $tmp/sbx-test-repo/.git" $log
check "main checkout has no --allow for the git dir"
grep -q -- "--allow $HOME/.ai/sbx-test-repo " $log; and test -d ~/.ai/sbx-test-repo
check "~/.ai/<slug> is made and allowed"
grep -q '^HERDR_AGENT=claude$' $log
check "HERDR_AGENT is claude"
grep -q "^CLAUDE_CONFIG_DIR=$HOME/.claude-sandbox/config\$" $log
and grep -q -- "--allow $HOME/.claude-sandbox " $log
check "sandbox config directory is set and allowed"
test (readlink ~/.claude-sandbox/config/skills) = $HOME/.claude/skills
and test (readlink ~/.claude-sandbox/config/CLAUDE.md) = $HOME/.claude/CLAUDE.md
check "sandbox config directory links to ~/.claude"
grep -q "^PATH1=$HOME/.config/agents/bin\$" $log
check "PATH starts with ~/.config/agents/bin"

# Case 2d: switch not on -> claude binary, no nono, also with a repo file
for value in off ''
    set -g claude_sandbox $value
    rm -f $log
    claude --version; claudes --version
    test (grep -c '^claude-binary --version$' $log) -eq 2; and not grep -q '^nono' $log
    check "claude_sandbox '$value' runs claude and claudes without nono"
end
set -g claude_sandbox on
rm -f $log
claude_sandbox=off claude --version
grep -q '^claude-binary --version$' $log; and not grep -q '^nono' $log
check "claude_sandbox=off prefix runs one claude without nono"

# Case 2a: Herdr title only in Herdr, only on the terminal. script gives the child a terminal.
function tty_output --argument-names herdr_env
    script -q /dev/null fish -c "source ~/.config/fish/conf.d/claude.fish
        function nono; end; function adb; end; set -g claude_sandbox on
        cd $tmp/sbx-test-repo; HERDR_ENV=$herdr_env claude --version >/dev/null 2>&1" </dev/null \
        | string collect
end
string match -q -- '*nono sandbox starting*' (tty_output 1)
check "Herdr gets the starting title on the terminal"
not string match -q -- '*nono sandbox starting*' (HERDR_ENV=1 claude --version | string collect)
check "no title on stdout"
not string match -q -- '*nono sandbox starting*' (tty_output '')
check "no title outside Herdr"

# Case 2b: linked worktree -> --allow <common dir>
git -C "$tmp/sbx-test-repo" worktree add -q "$tmp/sbx-test-wt" -b wt
cd "$tmp/sbx-test-wt"
rm -f $log
claude
grep -q -- "--allow $tmp/sbx-test-repo/.git" $log
check "worktree adds --allow for the git common dir"
grep -q -- "$tmp/sbx-test-repo/.git/worktrees/sbx-test-wt/nono-gradle-daemons" $log
check "worktree registry is in the worktree git dir"

# Case 2c: local layer
echo '{"meta":{"name":"claude-android-local"}}' >$tmp/local.json
set -l had_local 0
test -f $profiles/claude-android-local.json; and set had_local 1
if test $had_local -eq 0
    cp $tmp/local.json $profiles/claude-android-local.json
    cd "$tmp/sbx-test-repo"
    rm -f $log
    claude
    grep -q -- '--extends claude-android-local' $log
    check "local layer is added"
    rm $profiles/claude-android-local.json
end

# Case 3: repo file with no extends -> error, no claude at all
echo '{"meta":{"name":"repo-sbx-test-repo"}}' >$profiles/repo-sbx-test-repo.json
cd "$tmp/sbx-test-repo"
rm -f $log
claude --version 2>/dev/null
set -l code $status
test $code -ne 0; and not grep -q -E '^(nono|claude-binary)' $log
check "bad repo file fails closed"
echo '{"extends":"claude-android","meta":{"name":"repo-sbx-test-repo"}}' >$profiles/repo-sbx-test-repo.json

# Case 4: path with a space -> registry path is quoted in JDK_JAVA_OPTIONS
new_repo "$tmp/space dir/sbx-test-repo"
cd "$tmp/space dir/sbx-test-repo"
rm -f $log
claude
grep -q -- "-Dorg.gradle.daemon.registry.base=\"$tmp/space dir/sbx-test-repo/.git/nono-gradle-daemons/" $log
check "registry path with a space is quoted"

# Case 5: two runs -> different ports
cd "$tmp/sbx-test-repo"
rm -f $log
claude; claude
set -l ports (string match -r -g -- '--proxy-port ([0-9]+)' <$log)
test (count $ports) -eq 2; and test "$ports[1]" != "$ports[2]"
check "each session gets its own port"

# Case 6: no slug -> error, no claude at all
mkdir -p $tmp/no-slug/.config/agents/bin
printf '#!/bin/sh\n' >$tmp/no-slug/.config/agents/bin/repo-slug.sh
chmod +x $tmp/no-slug/.config/agents/bin/repo-slug.sh
rm -f $log
HOME=$tmp/no-slug claude --version 2>$tmp/err
set -l code $status
test $code -ne 0; and not grep -q -E '^(nono|claude-binary)' $log
and grep -q "printed no slug" $tmp/err
check "empty slug fails closed"

# Case 6a: slug with two lines -> error, no claude at all
mkdir -p $tmp/two-slugs/.config/agents/bin
printf '#!/bin/sh\necho sbx-test-repo\necho other\n' >$tmp/two-slugs/.config/agents/bin/repo-slug.sh
chmod +x $tmp/two-slugs/.config/agents/bin/repo-slug.sh
rm -f $log
HOME=$tmp/two-slugs claude --version 2>$tmp/err
set -l code $status
test $code -ne 0; and not grep -q -E '^(nono|claude-binary)' $log
and grep -q "more than one line" $tmp/err
check "slug with two lines fails closed"

# Case 7: no free port -> error, no claude at all
mkdir -p $tmp/no-port
printf '#!/bin/sh\n' >$tmp/no-port/python3
chmod +x $tmp/no-port/python3
rm -f $log
begin
    set -lx PATH $tmp/no-port $PATH
    claude --version 2>$tmp/err
end
set -l code $status
test $code -ne 0; and not grep -q -E '^(nono|claude-binary)' $log
and grep -q "no free proxy port" $tmp/err
check "empty port fails closed"

# Case 8: claude-upgrade reads sandboxed session files and distrusts them. Fake HOME, fake panes,
# and a process named claude (a copy of fish, because macOS kills a copy of /bin/sleep). A session
# file with the PID of fish is a forged file.
set -l upgrade_home $tmp/upgrade-home
mkdir -p $upgrade_home/.claude/sessions $upgrade_home/.claude-sandbox/config/sessions
cp (status fish-path) $tmp/claude
$tmp/claude --no-config -c 'sleep 30' &
set -l claude_pid $last_pid
set -l parent_pid (string trim -- (ps -o ppid= -p $fish_pid))
function __claude_upgrade_available; echo "1 -> 2"; end
function __claude_mux; echo herdr; end
function __claude_pane_map --inherit-variable parent_pid
    echo "$fish_pid w9:p1"
    echo "$parent_pid w9:p2"
end
function __claude_pane_is_current; false; end
printf '{"pid":%s,"sessionId":"11111111-2222-3333-4444-555555555555","cwd":"/x","status":"idle\\\\u001b]2;evil\\\\u0007","name":"sandboxed","kind":"interactive"}' \
    $claude_pid >$upgrade_home/.claude-sandbox/config/sessions/a.json
printf '{"pid":%s,"sessionId":"11111111-2222-3333-4444-555555555556","cwd":"/x","status":"idle","name":"forged","kind":"interactive"}' \
    $fish_pid >$upgrade_home/.claude/sessions/b.json
set -l out (HOME=$upgrade_home claude-upgrade --dry-run | string collect)
kill $claude_pid
string match -q -- '*w9:p1*sandboxed*' $out
check "claude-upgrade finds a sandboxed session"
not string match -q -- '*forged*' $out
check "claude-upgrade skips a PID that is not claude"
not string match -q -- \e']2;evil*' $out; and string match -q -- '*IDLE]2;EVIL*' $out
check "claude-upgrade removes control characters from the status"

# Clean up
rm -f $profiles/repo-sbx-test-repo.json
rmdir ~/.ai/sbx-test-repo
cd /
rm -rf $tmp
echo "failures: $failures"
test $failures -eq 0
