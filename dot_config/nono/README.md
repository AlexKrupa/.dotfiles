# nono sandbox for Claude Code

The `claude` and `claudes` fish functions use these rules:

- If the universal fish variable `claude_sandbox` is `on` and the current repo has a profile,
  Claude Code starts in a `nono` sandbox.
- If not, Claude Code starts without a sandbox.

`claudes` (alias `cl`) also goes to the git root first. Herdr agents and `claude-upgrade`
relaunches use `claude`, so the same rules apply to them.

## Turn the sandbox on or off

The value is per computer, because chezmoi does not manage `fish_variables`. A change applies to
the next start in all fish shells.

- To use the sandbox on this computer, run `set -U claude_sandbox on`.
- To stop it, run `set -U claude_sandbox off`. An unset variable also means off.
- To start one session without the sandbox, run `claude_sandbox=off cl`.

## Profiles

All profiles are in `~/.config/nono/profiles/`. The sandbox can read this directory but cannot
write it.

| File                        | In dotfiles | Purpose                                     |
| --------------------------- | ----------- | ------------------------------------------- |
| `claude-android.json`       | yes         | Android, Gradle, Java, and Kotlin base      |
| `claude-android-local.json` | no          | Optional. Paths and domains for one machine |
| `repo-<slug>.json`          | no          | Turns on the sandbox for one repo           |

`<slug>` is the output of `~/.config/agents/bin/repo-slug.sh`. All worktrees of a repo use the same
file.

The `claude-android.json` profile has these settings:

- `~/Library/Android/sdk` is read-only. Its tool directories are on `PATH`. A writable SDK lets a
  sandboxed process replace `adb`. Install and update SDK packages outside the sandbox with the
  `android` CLI.
- The profile sets `JAVA_TOOL_OPTIONS=-Djava.net.preferIPv4Stack=true`. The `android` CLI is a
  native binary and ignores `JDK_JAVA_OPTIONS`. Each JVM prints `Picked up JAVA_TOOL_OPTIONS: ...`
  on stderr.
- The profile sets `GRADLE_OPTS` to the same value. Both values replace your own
  `JAVA_TOOL_OPTIONS` and `GRADLE_OPTS`. To use other values, set them in `environment.set_vars`
  of `claude-android-local.json`.
- The profile allows UDP to localhost. Gradle uses UDP to ask the owner of a `~/.gradle` cache
  lock to release it.
- The sandbox can write only the `~/.ai/<slug>` directory of the current repo. The launcher makes
  this directory and adds it with `--allow`.

## Read-only paths

Sessions outside the sandbox run or load these paths, and chezmoi can publish them. Thus the
sandbox cannot write, delete, or rename them:

- `~/.claude` and all files in it, and `~/.claude.json`
- In each repo: the `.git` directory or file itself, and in the `.git` directory `config`,
  `config.worktree`, `commondir`, `hooks/`, `worktrees/<name>/{commondir,gitdir,config.worktree}`,
  and `modules/<path>/{config,hooks/}`. In a linked worktree, the `.git` file and the `.git`
  directory of the main checkout.

Raw Seatbelt rules in `unsafe_macos_seatbelt_rules` set this. `nono why` does not show these
rules. The profile excludes the `unlink_protection` group of the `claude` pack. That group allows
delete and rename in all writable paths, also in the paths above.

The cost in the sandbox:

- Plugin installs and updates fail. Do them outside the sandbox.
- `git config` changes fail. Commits work.

## Claude Code config directory

Sandboxed sessions use `CLAUDE_CONFIG_DIR=~/.claude-sandbox/config`. The launcher makes it and
adds `~/.claude-sandbox` with `--allow`. Claude Code puts its lock directory `config.lock` next to
it.

- Settings: the launcher passes `--settings ~/.claude/settings.json`. Hooks, the statusline,
  plugins, and permissions come from that file. A key in that file wins over the same key in the
  sandbox settings.
- `/effort`, `/model`, `/config`, and "always allow" rules for all projects save in
  `~/.claude-sandbox/config/settings.json`. Sessions outside the sandbox do not see them. If
  `~/.claude/settings.json` has the same key, its value applies again at the next sandboxed start.
- Links in `~/.claude-sandbox/config` give read-only access to `CLAUDE.md`, `agents`,
  `commands`, `keybindings.json`, `output-styles`, `plugins`, `rules`, `skills`, and `themes` in
  `~/.claude`. If a name does not exist, the launcher makes the link.
- Session history is separate. `/resume`, `--continue`, and `--resume` find only the sessions of
  the same side, sandboxed or not. The prompt history is separate too.

## Login and Claude Code state

- The Keychain item of the login has the config directory in its key. Thus sandboxed sessions
  need their own `/login`, one time on each computer. One login covers all sandboxed sessions.
- `~/.claude-sandbox/config/.claude.json` keeps the login account, trusted folders, and
  user-scope MCP servers of sandboxed sessions. Add MCP servers in a sandboxed session with
  `claude mcp add --scope user`.
- To keep the state of an older setup, where sandboxed sessions used `~/.claude/.claude.json`,
  copy that file to `~/.claude-sandbox/config/.claude.json` before the first start. Then run
  `/login`.

## Turn on the sandbox for a repo

Run `claude-config` in the repo. It makes `repo-<slug>.json` and opens it in `$EDITOR`.

To let the agent read other repos, or connect to more hosts:

```json
{
  "extends": "claude-android",
  "meta": { "name": "repo-project-android" },
  "filesystem": { "read": ["$HOME/src/work/project-backend"] },
  "network": { "allow_domain": ["artifactory.example.com"] }
}
```

Put access for all repos on one machine in `claude-android-local.json`, with the same keys and
no `extends`.

## Find the cause of a denial

At session end, `nono` prints the denied paths and hosts, with `--allow-domain` hints. Use these
commands to look at one denial:

- Path: `nono why --profile repo-<slug> --path <path> --op read`
- Host: `nono why --profile repo-<slug> --host <host>`

To see the denials of a session after it ends (fish):

```fish
nono audit show (nono audit list --recent 1 --json | jq -r '.[0].session_id') 2>&1 | grep -i deny
```

`--recent 1` gives the newest `nono` session of any kind.

Claude can write a profile draft to `~/.config/nono/profile-drafts/`. Apply it with
`nono profile promote <name>`.

## Exit and grants

- At exit, `nono` can show a "Review denied paths" list. That list grants every row by default,
  also `~/.ssh`. Press Esc there, not Enter. Add paths with `claude-config`.
- The launcher passes `--suppress-save-prompt /`, so the list does not show for usual denials.
  It can still show a row for a damaged path, for example a path with shell text in it.
- A plain `nono run` without the launcher shows the list for each denial.
- `claude-upgrade` waits until `nono` exits, not only `claude`. While the list shows, `nono` does
  not exit. After 15 seconds, `claude-upgrade` skips the relaunch of that pane and types nothing
  into it.

## Gradle and Kotlin daemons

- Each session has its own Gradle daemon registry in `.git/nono-gradle-daemons/`.
- The sandbox cannot read `~/.gradle/daemon`. It cannot use daemons that run outside the sandbox.
- Kotlin compiles in the Gradle daemon (`in-process`).
- At session end, the launcher stops every process of the session that still runs. This includes
  Gradle daemons and background jobs that Claude started. Then it deletes the registry directory.

## Herdr

`herdr` runs through `nono` command mediation.

- The sandbox allows `agent`, `worktree`, `notification show`, `workspace get`,
  `pane current/move/close`, and `pane report-metadata` (statusline labels).
- The sandbox blocks `agent attach`, `agent start`, `pane run`, `pane send-keys`, and all other
  subcommands.
- `herdr-start-claude <name> <pane> <title> [<effort>]` in
  `~/.config/agents/integrations/claude-code` is a mediated command, and the launcher puts that
  directory first on `PATH`. It runs `herdr agent start
  <name> --kind claude --pane <pane> -- --name <title> [--effort <effort>]` outside the sandbox.
  It refuses arguments that start with `-` and unknown effort levels. Its `herdr` policy allows
  only `agent start`. `/work` uses it in the sandbox, and there `--effort` is the only Claude
  flag.
- The `herdr` command gets the `HERDR_*` variables. `--current` finds the caller pane.
- The launcher sets `HERDR_AGENT=claude`. Thus Herdr detects the sandboxed `claude`, and
  `herdr agent list` shows it with its state. In Herdr, the launcher sets the pane title
  `nono sandbox starting`. Herdr shows the pane as working until Claude Code starts. Thus
  `herdr agent start` waits for the Claude Code prompt, and `/work` delivers its prompt.
- In the sandbox, `/exec` and `/work` next mode run their helper as a Claude Code background
  task. `nono` blocks `herdr` calls from a detached process ("caller ancestry did not reach
  session root").

Risk: with `herdr-start-claude`, the sandbox can start `claude` in a pane of a repo with no repo
file, and prompt it. That agent can then do work outside the sandbox. The sandbox can also send
input to an agent that runs already, with `herdr agent prompt` and `herdr agent send-keys`.

Herdr limits:

- Each sandboxed start shows one `working` to `done` change, also with no prompt.
- When the helper of `/exec` or `/work` next mode ends, the new session gets a message about the
  background task. If the session is idle, this message can start one short turn.
- After a Herdr restart, Herdr cannot resume a sandboxed session. The Herdr hook of Claude Code
  cannot connect to the Herdr socket.

## Limits

- The emulator must start outside the sandbox. `claude` starts the `adb` server outside the
  sandbox.
- `git push` over SSH does not work. The proxy allows only HTTP and HTTPS.
- Signed commits fail in the sandbox, because the 1Password SSH agent socket is blocked.
  Unsigned commits work.
- The sandbox can read `~/.gradle/gradle.properties`. Do not put secrets there that the agent
  must not see.
- The sandbox can write the repo, including `gradlew` and build scripts. It can also write
  `~/.gradle` (for example `init.d`). Gradle runs these files later outside the sandbox with full
  rights. Review such changes before you run Gradle outside.
- The sandbox can write `.claude/settings.json`, `.claude/settings.local.json`, and `.mcp.json`
  in the repo. Sessions outside the sandbox in the same repo use these files, with their hooks
  and MCP servers. Review such changes before you start `claude` there without a sandbox.
- `adb connect <host>:<port>` in the sandbox makes the `adb` server outside the sandbox connect
  to any host. The host allowlist does not apply to it.

## Test

`fish ~/.config/nono/tests/claude-launcher.test.fish`

The test file writes a temporary `repo-sbx-test-repo.json` in the profile directory and makes
`~/.ai/sbx-test-repo`. It removes both at the end. It also makes `~/.claude-sandbox/config` and
its links, as a sandboxed start does.

`~/.config/agents/integrations/claude-code/herdr-start-claude.test.sh` tests the wrapper.
