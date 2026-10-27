//! A client of the test starts the daemon, and the end of the test stops it.

use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::{Run, TestEnv};

/// A client that hangs fails its test after this limit.
pub const CLIENT_SECONDS: u64 = 15;

static NEXT_OUTPUT: AtomicUsize = AtomicUsize::new(0);

/// One test daemon at a time, because parallel daemons slow the 1-second rounds that the checks
/// wait for.
static SERIAL: Mutex<()> = Mutex::new(());

pub struct Watchd {
    pub env: TestEnv,
    pub session: Child,
    pub events: PathBuf,
    pub watchd: PathBuf,
    fake_engine: bool,
    _serial: MutexGuard<'static, ()>,
}

pub fn ev(kind: &str, iid: u64) -> String {
    format!(r#"{{"kind":"{kind}","iid":{iid},"title":"Add foo","url":"u","actor":"anna","detail":"d","branch":"b"}}"#)
}

/// The daemon adds `row` as the last field.
pub fn norow(text: &str) -> String {
    text.lines()
        .map(|line| match line.rfind(r#","row":"#) {
            Some(start) if line.ends_with('}') => format!("{}}}", &line[..start]),
            _ => line.to_string(),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Sorts the keys, to compare a value of `debug state` with an expected text.
pub fn norm(text: &str) -> String {
    serde_json::from_str::<Value>(text).unwrap().to_string()
}

pub fn alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

pub fn is_daemon(pid: Option<u32>) -> bool {
    let Some(pid) = pid else { return false };
    let output = Command::new("ps")
        .args(["-o", "command=", "-p", &pid.to_string()])
        .output()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).contains("watchd daemon")
}

pub fn wait_for(seconds: u64, mut condition: impl FnMut() -> bool) -> bool {
    for _ in 0..seconds * 4 {
        if condition() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    false
}

pub fn sleep(seconds: u64) {
    std::thread::sleep(Duration::from_secs(seconds));
}

/// A stand-in session process for `WATCH_SESSION_PID`.
pub fn session() -> Child {
    Command::new("sleep").arg("600").spawn().unwrap()
}

pub fn end(mut child: Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// A command that does not stop in time is killed and gets exit code 124, as with `timeout`.
pub fn run_limited(mut command: Command, folder: &Path, seconds: u64) -> Run {
    let number = NEXT_OUTPUT.fetch_add(1, Ordering::SeqCst);
    let (out_path, err_path) = (
        folder.join(format!("run-{number}.out")),
        folder.join(format!("run-{number}.err")),
    );
    let mut child = command
        .stdout(std::fs::File::create(&out_path).unwrap())
        .stderr(std::fs::File::create(&err_path).unwrap())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let code = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status.code().unwrap_or(-1);
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            break 124;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let text = |path: &Path| {
        std::fs::read_to_string(path)
            .unwrap_or_default()
            .trim_end_matches('\n')
            .to_string()
    };
    Run {
        out: text(&out_path),
        err: text(&err_path),
        code,
    }
}

pub struct Background(JoinHandle<Run>);

impl Background {
    pub fn wait(self, seconds: u64) -> Option<Run> {
        if wait_for(seconds, || self.0.is_finished()) {
            self.0.join().ok()
        } else {
            None
        }
    }

    pub fn running(&self) -> bool {
        !self.0.is_finished()
    }

    pub fn code(self) -> String {
        self.wait(10).map_or(String::new(), |run| run.code.to_string())
    }
}

impl Watchd {
    pub fn new() -> Watchd {
        // A failed test leaves the lock poisoned: the next test can still run.
        let serial = SERIAL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let env = TestEnv::new();
        let events = env.dir.join("events");
        std::fs::create_dir_all(&events).unwrap();
        let herdr = format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"{}\"\nexit 0\n",
            env.dir.join("herdr.log").display()
        );
        super::executable(&env.dir.join("bin/herdr"), &herdr);
        let watchd = env.state.join("watchd");
        Watchd {
            session: session(),
            events,
            watchd,
            env,
            fake_engine: true,
            _serial: serial,
        }
    }

    pub fn with_gitlab_engine() -> Watchd {
        let mut watchd = Watchd::new();
        watchd.fake_engine = false;
        watchd
    }

    pub fn session_pid(&self) -> u32 {
        self.session.id()
    }

    pub fn command(&self) -> Command {
        self.command_of(Path::new(env!("CARGO_BIN_EXE_watchd")))
    }

    pub fn command_of(&self, program: &Path) -> Command {
        let mut command = self.env.command_of(program);
        for name in ["WATCHD_FAKE_ENGINE", "WATCHD_IDLE_SECONDS", "WATCHD_CLIENT_SECONDS"] {
            command.env_remove(name);
        }
        if self.fake_engine {
            command.env("WATCHD_FAKE_ENGINE", &self.events);
        }
        command
            .env("WATCHD_TICK", "1")
            .env("WATCH_CLIENT_TICK", "1")
            .env("WATCH_SESSION_PID", self.session_pid().to_string());
        command
    }

    pub fn watch_command(&self, args: &[&str]) -> Command {
        let mut command = self.command();
        command.args(["watch", "--interval", "1"]).args(args);
        command
    }

    pub fn run(&self, command: Command) -> Run {
        run_limited(command, &self.env.dir, CLIENT_SECONDS)
    }

    pub fn watch(&self, args: &[&str]) -> Run {
        self.run(self.watch_command(args))
    }

    pub fn client(&self, args: &[&str]) -> Run {
        let mut command = self.command();
        command.args(args);
        self.run(command)
    }

    pub fn client_in(&self, folder: &Path, args: &[&str]) -> Run {
        let mut command = self.command();
        command.current_dir(folder).args(args);
        self.run(command)
    }

    /// The local state of the worktree, or null.
    pub fn worktree_state(&self, path: &Path) -> Value {
        let file = self.watchd.join(format!("worktrees/{}.json", super::hash12(path)));
        match file.exists() {
            true => super::read_json(&file),
            false => Value::Null,
        }
    }

    pub fn report(&self, json: &str, flags: &[&str]) -> Run {
        let input = self.env.dir.join("report.json");
        std::fs::write(&input, json).unwrap();
        let mut command = self.command();
        command
            .arg("report")
            .args(flags)
            .stdin(std::fs::File::open(&input).unwrap());
        let run = self.run(command);
        let out = [run.out.as_str(), run.err.as_str()]
            .into_iter()
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        Run {
            out,
            err: String::new(),
            code: run.code,
        }
    }

    pub fn start(&self, command: Command) -> Background {
        let folder = self.env.dir.clone();
        Background(std::thread::spawn(move || {
            run_limited(command, &folder, CLIENT_SECONDS)
        }))
    }

    pub fn events(&self, key: &str, lines: &[String]) {
        let text: String = lines.iter().map(|line| format!("{line}\n")).collect();
        let path = self.events.join(format!("{key}.jsonl"));
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap();
        std::io::Write::write_all(&mut file, text.as_bytes()).unwrap();
    }

    /// `suffix` is `exit`, `err`, `state`, or `sleep`.
    pub fn fake(&self, key: &str, suffix: &str, text: &str) {
        std::fs::write(self.events.join(format!("{key}.{suffix}")), text).unwrap();
    }

    pub fn args(&self) -> String {
        std::fs::read_to_string(self.events.join("args")).unwrap_or_default()
    }

    pub fn clear_args(&self) {
        std::fs::write(self.events.join("args"), "").unwrap();
    }

    pub fn log(&self) -> String {
        std::fs::read_to_string(self.watchd.join("watchd.log")).unwrap_or_default()
    }

    pub fn log_count(&self, text: &str) -> usize {
        self.log().lines().filter(|line| line.contains(text)).count()
    }

    pub fn daemon_pid(&self) -> Option<u32> {
        std::fs::read_to_string(self.watchd.join("daemon.pid"))
            .ok()?
            .trim()
            .parse()
            .ok()
    }

    /// The state of the daemon, or the state on disk when no daemon runs.
    pub fn state(&self) -> Value {
        let run = self.client(&["debug", "state"]);
        serde_json::from_str(&run.out).unwrap_or(Value::Null)
    }

    pub fn sub_of(&self, key: &str) -> Value {
        self.state()["subs"][key].clone()
    }

    pub fn has_sub(&self, key: &str) -> bool {
        !self.sub_of(key).is_null()
    }

    pub fn sub_gone(&self, key: &str) -> &'static str {
        if self.has_sub(key) { "no" } else { "yes" }
    }

    pub fn inbox_of(&self, key: &str) -> String {
        let inbox = self.state()["inbox"][key].clone();
        let events = inbox.as_array().cloned().unwrap_or_default();
        events
            .into_iter()
            .map(|mut event| {
                event.as_object_mut().map(|event| event.remove("row"));
                event.to_string()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn has_error(&self, key: &str) -> bool {
        self.state()["errors"][key]
            .as_str()
            .is_some_and(|text| !text.is_empty())
    }

    pub fn items_of(&self, key: &str) -> Value {
        self.state()["items"][key].clone()
    }

    pub fn rounds_of(&self, key: &str) -> u64 {
        self.state()["rounds"][key].as_u64().unwrap_or(0)
    }

    pub fn client_is(&self) -> Value {
        self.sub_of("app")["client_pid"].clone()
    }

    pub fn stack_key(&self) -> String {
        format!("app-{}", self.env.worktree_hash())
    }

    pub fn herdr_called(&self) -> bool {
        self.env.dir.join("herdr.log").exists()
    }

    pub fn log_last(&self) -> Value {
        let text = std::fs::read_to_string(self.watchd.join("events.jsonl")).unwrap_or_default();
        text.lines()
            .last()
            .map_or(Value::Null, |line| serde_json::from_str(line).unwrap())
    }

    /// A `follow` client from the folder keeps the daemon up until the end of the test.
    pub fn follower(&self, folder: &Path) -> Child {
        let mut command = self.command();
        command.current_dir(folder).arg("follow");
        let (child, output) = self.spawn_logged(command, "follow.out");
        wait_for(10, || std::fs::metadata(&output).is_ok_and(|meta| meta.len() > 0));
        child
    }

    pub fn spawn_logged(&self, mut command: Command, name: &str) -> (Child, PathBuf) {
        let path = self.env.dir.join(name);
        let file = std::fs::File::create(&path).unwrap();
        let child = command.stdout(file.try_clone().unwrap()).stderr(file).spawn().unwrap();
        (child, path)
    }

    pub fn stop_daemon(&self) {
        let pid = self.daemon_pid();
        if is_daemon(pid) {
            let pid = pid.unwrap();
            unsafe { libc::kill(pid as i32, libc::SIGTERM) };
            wait_for(10, || !alive(pid));
        }
    }
}

impl Drop for Watchd {
    fn drop(&mut self) {
        self.stop_daemon();
        let _ = self.session.kill();
        let _ = self.session.wait();
    }
}
