#![allow(dead_code)]

pub mod daemon;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::Value;

pub const URL: &str = "https://gitlab.example.com/group/sub/app/-/merge_requests";
pub const PIPELINES: &str = "https://gitlab.example.com/group/sub/app/-/pipelines";

const FAKE_GLAB: &str = r##"#!/bin/sh
# One write for each line: calls in parallel append to one log, and printf writes a long line in
# parts.
perl -e 'syswrite STDOUT, "@ARGV\n"' -- "$@" >>"$MOCK_LOG"
if [ "$1" = auth ]; then [ -z "${MOCK_NOAUTH:-}" ]; exit; fi
[ "$1" = api ] || { echo "unexpected glab call: $*" >&2; exit 2; }
if [ -n "${MOCK_FAIL:-}" ]; then
  case "$2" in $MOCK_FAIL)
    n=$(($(cat "$MOCK_DIR/fails" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$MOCK_DIR/fails"
    if [ "$n" -le "${MOCK_FAIL_TIMES:-$n}" ]; then echo "$MOCK_FAIL_MSG" >&2; exit 1; fi ;;
  esac
fi
if [ "$2" = graphql ]; then
  iid=
  for a; do case $a in iid=*) iid=${a#iid=} ;; esac; done
  f="$MOCK_DIR/gql_$iid.json"
  if [ ! -f "$f" ]; then
    echo '{"data": {"currentUser": {"username": "me"}, "project": {"mergeRequest": null}}}'; exit
  fi
  cat "$f"
  # Like glab: a response with errors also goes to stderr, and the exit code is 1.
  msg=$(jq -r '[.errors[]?.message] | join("; ")' "$f")
  if [ -n "$msg" ]; then echo "glab: $msg" >&2; exit 1; fi
  exit
fi
iid=$(echo "$2" | cut -d/ -f4 | cut -d'?' -f1)
case "$2" in
  user) f=user ;;
  projects/group%2Fsub%2Fapp) f=project ;;
  todos\?*) f=todos ;;
  users/1/events\?*) f=events ;;
  projects/7/merge_requests\?author_username=*) echo "own MRs call: $2" >&2; exit 2 ;;
  projects/7/merge_requests\?state=opened\&*) f=opened ;;
  projects/7/merge_requests\?*) f=commented ;;
  projects/*/merge_requests/*/notes/*/award_emoji\?*) f=award_note_$(echo "$2" | cut -d/ -f6) ;;
  projects/*/merge_requests/*/award_emoji\?*) f=award_mr_$iid ;;
  projects/group%2Fsub%2Fapp/merge_requests/*/discussions\?*) f=discussions_$iid ;;
  projects/group%2Fsub%2Fapp/merge_requests/*) f=mr_$iid ;;
  projects/7/merge_requests/*/approvals) f=approvals_$iid ;;
  projects/7/merge_requests/*/notes\?*) f=notes_$iid ;;
  projects/*/pipelines/*/jobs\?*) f=jobs_$(echo "$2" | cut -d/ -f4) ;;
  projects/7/pipelines\?*) f=pipelines ;;
  projects/7/merge_requests/*) f=mr_$iid ;;
  *) echo "unexpected glab api path: $2" >&2; exit 2 ;;
esac
if [ -f "$MOCK_DIR/$f.json" ]; then
  cat "$MOCK_DIR/$f.json"
  case " $* " in *" --paginate "*) cat "$MOCK_DIR/${f}_p"[0-9].json 2>/dev/null || true ;; esac
  exit
fi
case "$f" in
  mr_*) echo '{}' ;;
  approvals_*) echo '{"approved_by": []}' ;;
  *) echo '[]' ;;
esac
"##;

/// `pmset` output for full wake with the network up.
const FAKE_PMSET: &str = "#!/bin/sh\necho \"Current System Capabilities are: CPU Graphics Audio Network\"\n";
const FAKE_NC: &str = "#!/bin/sh\nexit 0\n";

static NEXT: AtomicUsize = AtomicUsize::new(0);

pub struct TestEnv {
    pub dir: PathBuf,
    pub state: PathBuf,
    pub repo: PathBuf,
    pub mock: PathBuf,
    env: Vec<(String, String)>,
}

/// The trailing newlines are gone, as in `$(...)` of the shell.
pub struct Run {
    pub out: String,
    pub err: String,
    pub code: i32,
}

impl Run {
    pub fn of(output: Output) -> Run {
        let text = |bytes: &[u8]| String::from_utf8_lossy(bytes).trim_end_matches('\n').to_string();
        Run { out: text(&output.stdout), err: text(&output.stderr), code: output.status.code().unwrap_or(-1) }
    }
}

fn executable(path: &Path, text: &str) {
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

impl TestEnv {
    pub fn new() -> TestEnv {
        let number = NEXT.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("watchd-test-{}-{number}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // The engine sees the worktree top that git gives: the path with no symlinks.
        let dir = dir.canonicalize().unwrap();
        for name in ["bin", "mock", "state"] {
            std::fs::create_dir_all(dir.join(name)).unwrap();
        }
        executable(&dir.join("bin/glab"), FAKE_GLAB);
        executable(&dir.join("bin/pmset"), FAKE_PMSET);
        executable(&dir.join("bin/nc"), FAKE_NC);
        std::fs::write(dir.join("gitconfig"), "[init]\n\tdefaultBranch = main\n").unwrap();
        let env = TestEnv {
            state: dir.join("state"),
            repo: dir.join("app"),
            mock: dir.join("mock"),
            dir,
            env: Vec::new(),
        };
        env.git_repo(&env.repo, "https://gitlab.example.com/group/sub/app.git");
        env.fixture("user", r#"{"id": 1, "username": "me"}"#);
        env.fixture("project", r#"{"id": 7, "default_branch": "dev/x"}"#);
        env
    }

    pub fn git_repo(&self, folder: &Path, origin: &str) {
        for args in [vec!["init", "-q", folder.to_str().unwrap()], vec!["-C", folder.to_str().unwrap(), "remote", "add", "origin", origin]] {
            let status = Command::new("git")
                .args(args)
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .env("GIT_CONFIG_GLOBAL", self.dir.join("gitconfig"))
                .status()
                .unwrap();
            assert!(status.success());
        }
    }

    pub fn fixture(&self, name: &str, json: &str) {
        std::fs::write(self.mock.join(format!("{name}.json")), format!("{json}\n")).unwrap();
    }

    pub fn set_env(&mut self, name: &str, value: &str) {
        self.remove_env(name);
        self.env.push((name.to_string(), value.to_string()));
    }

    pub fn remove_env(&mut self, name: &str) {
        self.env.retain(|(key, _)| key != name);
    }

    pub fn command(&self) -> Command {
        self.command_of(Path::new(env!("CARGO_BIN_EXE_watchd")))
    }

    pub fn command_of(&self, program: &Path) -> Command {
        let mut command = Command::new(program);
        let path = format!("{}:{}", self.dir.join("bin").display(), std::env::var("PATH").unwrap_or_default());
        command
            .current_dir(&self.repo)
            .stdin(Stdio::null())
            .env("PATH", path)
            .env("XDG_STATE_HOME", &self.state)
            .env("MOCK_LOG", self.dir.join("calls.log"))
            .env("MOCK_DIR", &self.mock)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", self.dir.join("gitconfig"));
        // The tests must never reach the real herdr, and the variables of the test process do
        // not go to the child.
        for name in ["HERDR_ENV", "HERDR_WORKSPACE_ID", "HERDR_PANE_ID", "HERDR_SOCKET_PATH", "WATCH_MR_CACHE",
            "MOCK_FAIL", "MOCK_FAIL_MSG", "MOCK_FAIL_TIMES", "MOCK_NOAUTH"]
        {
            command.env_remove(name);
        }
        for (name, value) in &self.env {
            command.env(name, value);
        }
        command
    }

    pub fn run_engine(&self, args: &[&str]) -> Output {
        self.command().arg("engine").args(args).output().unwrap()
    }

    pub fn run(&self, args: &[&str]) -> Run {
        Run::of(self.run_engine(args))
    }

    pub fn run_in(&self, folder: &Path, args: &[&str]) -> Run {
        Run::of(self.command().current_dir(folder).arg("engine").args(args).output().unwrap())
    }

    pub fn calls(&self) -> String {
        std::fs::read_to_string(self.dir.join("calls.log")).unwrap_or_default()
    }

    pub fn clear_calls(&self) {
        std::fs::write(self.dir.join("calls.log"), "").unwrap();
    }

    pub fn calls_with(&self, prefix: &str) -> String {
        self.calls().lines().filter(|line| line.starts_with(prefix)).collect::<Vec<_>>().join("\n")
    }

    pub fn worktree_hash(&self) -> String {
        let mut child = Command::new("shasum").stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
        std::io::Write::write_all(child.stdin.as_mut().unwrap(), self.repo.to_str().unwrap().as_bytes()).unwrap();
        let output = child.wait_with_output().unwrap();
        String::from_utf8_lossy(&output.stdout)[..12].to_string()
    }

    pub fn engine_state(&self, key: &str) -> PathBuf {
        self.state.join(format!("watch-gitlab/{key}.json"))
    }

    pub fn write_engine_state(&self, key: &str, json: &str) {
        let path = self.engine_state(key);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, format!("{json}\n")).unwrap();
    }
}

impl Drop for TestEnv {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A scenario runs once, and each of its checks is one test.
#[derive(Default)]
pub struct Checks(Vec<(String, String, String)>);

impl Checks {
    pub fn check(&mut self, name: &str, expected: impl ToString, actual: impl ToString) {
        self.0.push((name.to_string(), expected.to_string(), actual.to_string()));
    }

    pub fn assert(&self, name: &str) {
        let (_, expected, actual) =
            self.0.iter().find(|(check, ..)| check == name).unwrap_or_else(|| panic!("no check named {name:?}"));
        assert_eq!(actual, expected, "{name}");
    }
}

pub fn raw(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

pub fn each(out: &str, key: &str) -> String {
    out.lines()
        .map(|line| raw(&serde_json::from_str::<Value>(line).unwrap()[key]))
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn read_json(path: &Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

pub fn field(path: &Path, key: &str) -> String {
    read_json(path)[key].to_string()
}

pub fn yes_no(path: &Path) -> &'static str {
    if path.exists() { "yes" } else { "no" }
}
