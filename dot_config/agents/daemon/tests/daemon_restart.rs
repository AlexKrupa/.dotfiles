mod support;

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

use serde_json::json;
use support::Checks;
use support::daemon::{Watchd, alive, ev, is_daemon, norow, wait_for};
use watchd::daemon::store::UPGRADE_TEXT;

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

/// A check installs a new binary over this copy under a live daemon and client.
fn copy_binary(w: &Watchd) -> PathBuf {
    let copy = w.env.dir.join("bin/watchd");
    std::fs::copy(env!("CARGO_BIN_EXE_watchd"), &copy).unwrap();
    copy
}

/// The rename gives the binary a new inode, as build.sh does.
fn install_copy(copy: &Path) {
    let new = copy.with_extension("new");
    std::fs::copy(copy, &new).unwrap();
    std::fs::rename(&new, copy).unwrap();
}

fn watch_copy(w: &Watchd, copy: &Path, args: &[&str]) -> Command {
    let mut command = w.command_of(copy);
    command
        .args(["watch", "--interval", "1", "--session", &w.session_id()])
        .args(args);
    command
}

fn wait_copy(w: &Watchd, copy: &Path) -> Command {
    let mut command = w.command_of(copy);
    let pid = w.session_pid().to_string();
    command.args(["wait", "--session", &w.session_id(), "--owner-pid", &pid]);
    command
}

fn starts_of(w: &Watchd, pid: Option<u32>) -> usize {
    let line = format!("daemon start {}", pid.unwrap_or(0));
    w.log().lines().filter(|text| text.ends_with(&line)).count()
}

fn kill(pid: Option<u32>, signal: i32) {
    unsafe { libc::kill(pid.unwrap_or(0) as i32, signal) };
}

/// The fake engine writes `args` before it takes the events.
fn events_taken(w: &Watchd) -> bool {
    std::fs::read_to_string(w.events.join("app.jsonl")).is_ok_and(|text| text.is_empty())
}

fn new_binary() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let copy = copy_binary(&w);
        w.events("app", &[ev("todo", 5)]);
        w.run(watch_copy(&w, &copy, &[]));
        w.run(wait_copy(&w, &copy));
        let old = w.daemon_pid();
        install_copy(&copy);
        wait_for(10, || starts_of(&w, old) == 2);
        w.events("app", &[ev("todo", 6)]);
        w.run(watch_copy(&w, &copy, &[]));
        let run = w.run(wait_copy(&w, &copy));
        c.check(
            "a new binary is installed: the daemon restarts with the same PID",
            format!("0 {} 2 yes", ev("todo", 6)),
            format!(
                "{} {} {} {}",
                run.code,
                norow(&run.out),
                starts_of(&w, old),
                yes_no(w.daemon_pid() == old && is_daemon(old))
            ),
        );
        c
    })
}

fn new_binary_client() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let copy = copy_binary(&w);
        w.run(watch_copy(&w, &copy, &["--interval", "600", "--fresh"]));
        let client = w.start(wait_copy(&w, &copy));
        wait_for(10, || w.rounds_of("app") >= 1 && w.waiting(&w.session_id()));
        let old = w.daemon_pid();
        w.env.write_engine_state("app", r#"{"version": 4, "todo": 1}"#);
        // The interval is long: the round of this event is the first round of the new daemon.
        w.events("app", &[ev("todo", 5)]);
        install_copy(&copy);
        let run = client.wait(10).unwrap();
        c.check(
            "a new binary: the client connects again and gets the events once",
            format!("0 {} 2", ev("todo", 5)),
            format!("{} {} {}", run.code, norow(&run.out), starts_of(&w, old)),
        );
        let sub = w.sub_of("app");
        let fresh = w.state()["engine"]["app"]["todo"].is_null();
        c.check(
            "a new binary: the record keeps its flags, and the engine state stays",
            "600 no",
            format!("{} {}", sub["interval"], yes_no(fresh)),
        );
        c
    })
}

fn daemon_killed() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.watch(&[]);
        let client = w.start(w.wait_command());
        wait_for(10, || w.waiting(&w.session_id()));
        let old = w.daemon_pid();
        kill(old, libc::SIGKILL);
        w.events("app", &[ev("todo", 7)]);
        let run = client.wait(10).unwrap();
        c.check(
            "daemon killed: client starts it, event not lost",
            format!("0 {}", ev("todo", 7)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        c.check(
            "daemon killed: new daemon",
            "yes",
            yes_no(w.daemon_pid() != old && is_daemon(w.daemon_pid())),
        );
        c
    })
}

fn slow_check(w: &Watchd) -> support::daemon::Background {
    w.events("app", &[ev("todo", 5)]);
    w.watch_wait(&["--interval", "600"]);
    w.fake("app", "sleep", "3\n");
    w.events("app", &[ev("todo", 6)]);
    w.watch(&["--interval", "600"]);
    let client = w.start(w.wait_command());
    wait_for(5, || events_taken(w));
    client
}

fn killed_during_check() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let client = slow_check(&w);
        kill(w.daemon_pid(), libc::SIGKILL);
        w.events("app", &[ev("todo", 8)]);
        let run = client.wait(10).unwrap();
        c.check(
            "daemon killed during a check: client starts it, the next check gives the event",
            format!("0 {}", ev("todo", 8)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        c
    })
}

fn leftover_socket() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        std::fs::create_dir_all(&w.watchd).unwrap();
        std::fs::write(w.watchd.join("daemon.sock"), "").unwrap();
        w.events("app", &[ev("todo", 5)]);
        let run = w.watch_wait(&[]);
        c.check(
            "leftover socket file with no daemon: client gets events",
            format!("0 {}", ev("todo", 5)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        c
    })
}

fn log_size() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        std::fs::create_dir_all(&w.watchd).unwrap();
        let lines: String = (1..=12000).map(|number| format!("{number}\n")).collect();
        std::fs::write(w.watchd.join("watchd.log"), lines).unwrap();
        w.events("app", &[ev("todo", 5)]);
        w.watch(&[]);
        c.check(
            "log over 10000 lines: the daemon keeps the last 5000",
            "7001",
            w.log().lines().next().unwrap_or_default().to_string(),
        );
        c
    })
}

fn sigterm_during_check() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let client = slow_check(&w);
        let pid = w.daemon_pid();
        kill(pid, libc::SIGTERM);
        let run = client.wait(10).unwrap();
        c.check(
            "the daemon gets SIGTERM during a check: event not lost",
            format!("0 {}", ev("todo", 6)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        c.check(
            "the daemon gets SIGTERM during a check: daemon gone",
            "no",
            yes_no(alive(pid.unwrap_or(0))),
        );
        c
    })
}

fn network_down() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let nc = w.env.dir.join("bin/nc");
        w.events("app", &[ev("todo", 5)]);
        w.watch_wait(&[]);
        std::fs::write(&nc, "#!/bin/sh\nexit 1\n").unwrap();
        w.fake("app", "exit", "4\n");
        w.watch(&[]);
        let client = w.start(w.wait_command());
        wait_for(5, || w.log_count("network error") > 0);
        w.local_rounds(2);
        c.check(
            "network down: no client error, subscription stays",
            "running no",
            format!(
                "{} {}",
                if client.running() { "running" } else { "stopped" },
                w.sub_gone("app")
            ),
        );
        w.unsubscribe(&["--repo", w.env.repo.to_str().unwrap()]);
        client.code();
        std::fs::write(&nc, "#!/bin/sh\nexit 0\n").unwrap();
        c
    })
}

/// The state folder of a daemon of an older format: a hub watch of the session, an event in its
/// inbox that the session did not get, a session whose watch the user stopped, and the files that
/// a format change keeps.
fn old_state(w: &Watchd, format: Option<&str>) {
    for folder in ["subs", "sessions", "inbox"] {
        std::fs::create_dir_all(w.watchd.join(folder)).unwrap();
    }
    if let Some(format) = format {
        std::fs::write(w.watchd.join("format"), format!("{format}\n")).unwrap();
    }
    std::fs::write(w.watchd.join("daemon.lock"), "").unwrap();
    std::fs::write(w.watchd.join("watchd.log"), "old line\n").unwrap();
    let id = w.session_id();
    let sub = json!({
        "version": 4, "key": "app", "slug": "app", "repo": w.env.repo, "mode": "hub", "mrs": [],
        "interval": 1, "session": id, "ended_mrs": [],
    });
    std::fs::write(w.watchd.join("subs/app.json"), sub.to_string()).unwrap();
    let session = json!({"version": 4, "owner_pid": w.session_pid(), "owner_gone_at": null});
    std::fs::write(w.watchd.join(format!("sessions/{id}.json")), session.to_string()).unwrap();
    std::fs::write(w.watchd.join("sessions/stopped.json"), session.to_string()).unwrap();
    let routed = ev("pipeline", 5).replacen('}', r#","row":1}"#, 1);
    std::fs::write(w.watchd.join("inbox/app.jsonl"), format!("{routed}\n")).unwrap();
}

fn entry_count(folder: &Path) -> usize {
    std::fs::read_dir(folder).map_or(0, |entries| entries.count())
}

fn format_of(w: &Watchd) -> String {
    std::fs::read_to_string(w.watchd.join("format"))
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn format_change() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        old_state(&w, Some("3"));
        w.fake(
            "app",
            "state",
            r#"{"version": 4, "default_pipeline": {"id": 1, "status": "success"}}"#,
        );
        let first = w.wait();
        c.check(
            "a format change deletes the state and keeps the lock and the log",
            "0 4 1 old line yes",
            format!(
                "{} {} {} {} {}",
                entry_count(&w.watchd.join("subs")),
                format_of(&w),
                w.log_count("state reset: format 3 to 4"),
                w.log().lines().next().unwrap_or_default(),
                yes_no(w.watchd.join("daemon.lock").exists())
            ),
        );
        let second = w.wait();
        c.check(
            "a wait after an upgrade gets the upgrade error",
            "1 yes 0 []",
            format!(
                "{} {} {} [{}]",
                first.code,
                yes_no(first.err.contains(UPGRADE_TEXT)),
                second.code,
                second.err
            ),
        );
        let other = w.run(w.as_session(w.wait_command(), "s9", std::process::id()));
        c.check(
            "a session with no watch gets no upgrade error",
            "0 [] []",
            format!("{} [{}] [{}]", other.code, other.out, other.err),
        );
        let stopped = w.run(w.as_session(w.wait_command(), "stopped", std::process::id()));
        c.check(
            "a session with a session file but no record gets no upgrade error",
            "0 [] []",
            format!("{} [{}] [{}]", stopped.code, stopped.out, stopped.err),
        );
        assert_eq!(w.watch(&[]).code, 0);
        wait_for(10, || w.rounds_of("app") >= 1);
        c.check(
            "the first check after a reset sends no event",
            "[] [] []",
            format!(
                "[{}] [{}] [{}]",
                norow(&first.out),
                norow(&second.out),
                w.inbox_of("app")
            ),
        );
        w.events("app", &[ev("todo", 6)]);
        let run = w.wait();
        c.check(
            "a new watch after an upgrade gets events again",
            format!("0 {}", ev("todo", 6)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        c
    })
}

#[test]
fn a_format_change_deletes_the_state_and_keeps_the_lock_and_the_log() {
    format_change().assert("a format change deletes the state and keeps the lock and the log");
}

#[test]
fn a_session_with_a_session_file_but_no_record_gets_no_upgrade_error() {
    format_change().assert("a session with a session file but no record gets no upgrade error");
}

#[test]
fn a_wait_after_an_upgrade_gets_the_upgrade_error() {
    format_change().assert("a wait after an upgrade gets the upgrade error");
}

#[test]
fn a_session_with_no_watch_gets_no_upgrade_error() {
    format_change().assert("a session with no watch gets no upgrade error");
}

#[test]
fn the_first_check_after_a_reset_sends_no_event() {
    format_change().assert("the first check after a reset sends no event");
}

#[test]
fn a_new_watch_after_an_upgrade_gets_events_again() {
    format_change().assert("a new watch after an upgrade gets events again");
}

fn inode_of(path: &Path) -> u64 {
    std::fs::metadata(path).map_or(0, |meta| std::os::unix::fs::MetadataExt::ino(&meta))
}

/// The inodes of the lock, the PID file, and the socket, and the first log line.
fn kept_entries(w: &Watchd) -> String {
    let inodes: Vec<String> = ["daemon.lock", "daemon.pid", "daemon.sock"]
        .iter()
        .map(|name| inode_of(&w.watchd.join(name)).to_string())
        .collect();
    format!("{} {}", inodes.join(" "), w.log().lines().next().unwrap_or_default())
}

/// A new binary with a new format, under a live daemon with a watch and a waiting client.
fn live_upgrade() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let copy = copy_binary(&w);
        w.run(watch_copy(&w, &copy, &[]));
        let client = w.start(wait_copy(&w, &copy));
        wait_for(10, || w.rounds_of("app") >= 1 && w.waiting(&w.session_id()));
        let old = w.daemon_pid();
        let kept = kept_entries(&w);
        let socket = inode_of(&w.watchd.join("daemon.sock"));
        std::fs::write(w.watchd.join("format"), "3\n").unwrap();
        install_copy(&copy);
        let first = client.wait(10).unwrap();
        c.check(
            "a live upgrade: the waiting client gets the upgrade error",
            "1 yes",
            format!("{} {}", first.code, yes_no(first.err.contains(UPGRADE_TEXT))),
        );
        c.check(
            "a live upgrade: the daemon keeps the lock, PID, socket, and log",
            format!("{kept} 2 1 yes"),
            format!(
                "{} {} {} {}",
                kept_entries(&w),
                starts_of(&w, old),
                w.log_count("state reset: format 3 to 4"),
                yes_no(w.daemon_pid() == old && is_daemon(old))
            ),
        );
        let watch = w.run(watch_copy(&w, &copy, &[]));
        w.events("app", &[ev("todo", 7)]);
        let run = w.run(wait_copy(&w, &copy));
        c.check(
            "a live upgrade: the same socket serves the new watch, and its events arrive",
            format!("0 {socket} 0 {} []", ev("todo", 7)),
            format!(
                "{} {} {} {} [{}]",
                watch.code,
                inode_of(&w.watchd.join("daemon.sock")),
                run.code,
                norow(&run.out),
                run.err
            ),
        );
        c
    })
}

#[test]
fn a_live_upgrade_the_waiting_client_gets_the_upgrade_error() {
    live_upgrade().assert("a live upgrade: the waiting client gets the upgrade error");
}

#[test]
fn a_live_upgrade_the_daemon_keeps_the_lock_pid_socket_and_log() {
    live_upgrade().assert("a live upgrade: the daemon keeps the lock, PID, socket, and log");
}

#[test]
fn a_live_upgrade_the_same_socket_serves_the_new_watch_and_its_events_arrive() {
    live_upgrade().assert("a live upgrade: the same socket serves the new watch, and its events arrive");
}

#[test]
fn a_missing_format_file_is_a_format_change() {
    let w = Watchd::new();
    old_state(&w, None);

    let run = w.wait();

    assert_eq!(run.code, 1, "{}", run.err);
    assert_eq!(entry_count(&w.watchd.join("subs")), 0);
    assert_eq!(format_of(&w), "4");
    assert_eq!(w.log_count("state reset: format none to 4"), 1, "{}", w.log());
}

#[test]
fn a_new_state_folder_gets_the_format_file_and_no_reset() {
    let w = Watchd::new();

    assert_eq!(w.watch(&[]).code, 0);

    assert_eq!(format_of(&w), "4");
    assert_eq!(w.log_count("state reset"), 0, "{}", w.log());
}

#[test]
fn a_new_binary_is_installed_the_daemon_restarts_with_the_same_pid() {
    new_binary().assert("a new binary is installed: the daemon restarts with the same PID");
}

#[test]
fn a_new_binary_the_client_connects_again_and_gets_the_events_once() {
    new_binary_client().assert("a new binary: the client connects again and gets the events once");
}

#[test]
fn a_new_binary_the_record_keeps_its_flags_and_the_engine_state_stays() {
    new_binary_client().assert("a new binary: the record keeps its flags, and the engine state stays");
}

#[test]
fn daemon_killed_client_starts_it_event_not_lost() {
    daemon_killed().assert("daemon killed: client starts it, event not lost");
}

#[test]
fn daemon_killed_new_daemon() {
    daemon_killed().assert("daemon killed: new daemon");
}

#[test]
fn daemon_killed_during_a_check_client_starts_it_the_next_check_gives_the_event() {
    killed_during_check().assert("daemon killed during a check: client starts it, the next check gives the event");
}

#[test]
fn leftover_socket_file_with_no_daemon_client_gets_events() {
    leftover_socket().assert("leftover socket file with no daemon: client gets events");
}

#[test]
fn log_over_10000_lines_the_daemon_keeps_the_last_5000() {
    log_size().assert("log over 10000 lines: the daemon keeps the last 5000");
}

#[test]
fn the_daemon_gets_sigterm_during_a_check_event_not_lost() {
    sigterm_during_check().assert("the daemon gets SIGTERM during a check: event not lost");
}

#[test]
fn the_daemon_gets_sigterm_during_a_check_daemon_gone() {
    sigterm_during_check().assert("the daemon gets SIGTERM during a check: daemon gone");
}

#[test]
fn network_down_no_client_error_subscription_stays() {
    network_down().assert("network down: no client error, subscription stays");
}

#[test]
fn a_new_session_id_of_the_same_owner_after_an_upgrade_gets_the_upgrade_error() {
    let w = Watchd::new();
    old_state(&w, Some("3"));
    let mut command = w.as_session(w.wait_command(), "cleared", w.session_pid());
    command.arg("--rename-owner-session");

    let cleared = w.run(command);

    assert_eq!(cleared.code, 1, "{}", cleared.err);
    assert!(cleared.err.contains(UPGRADE_TEXT), "{}", cleared.err);
}

#[test]
fn a_watch_after_an_upgrade_removes_the_upgrade_error() {
    let w = Watchd::new();
    old_state(&w, Some("3"));

    assert_eq!(w.watch(&[]).code, 0);
    w.events("app", &[ev("todo", 6)]);
    let run = w.wait();

    assert_eq!((run.code, norow(&run.out)), (0, ev("todo", 6)), "{}", run.err);
}
