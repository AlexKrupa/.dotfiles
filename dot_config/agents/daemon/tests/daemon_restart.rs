mod support;

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

use support::Checks;
use support::daemon::{Watchd, alive, ev, is_daemon, norow, sleep, wait_for};

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
    command.args(["watch", "--interval", "1"]).args(args);
    command
}

fn starts_of(w: &Watchd, pid: Option<u32>) -> usize {
    let line = format!("daemon start {}", pid.unwrap_or(0));
    w.log().lines().filter(|text| text.ends_with(&line)).count()
}

fn kill(pid: Option<u32>, signal: i32) {
    unsafe { libc::kill(pid.unwrap_or(0) as i32, signal) };
}

fn args_written(w: &Watchd) -> bool {
    !w.args().is_empty()
}

fn new_binary() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let copy = copy_binary(&w);
        w.events("app", &[ev("todo", 5)]);
        w.run(watch_copy(&w, &copy, &[]));
        let old = w.daemon_pid();
        install_copy(&copy);
        wait_for(10, || starts_of(&w, old) == 2);
        w.events("app", &[ev("todo", 6)]);
        let run = w.run(watch_copy(&w, &copy, &[]));
        c.check("a new binary is installed: the daemon restarts with the same PID", format!("0 {} 2 yes", ev("todo", 6)),
            format!("{} {} {} {}", run.code, norow(&run.out), starts_of(&w, old), yes_no(w.daemon_pid() == old && is_daemon(old))));
        c
    })
}

fn new_binary_client() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let copy = copy_binary(&w);
        let client = w.start(watch_copy(&w, &copy, &["--interval", "600", "--fresh"]));
        wait_for(10, || w.has_sub("app") && w.rounds_of("app") >= 1);
        let old = w.daemon_pid();
        let client_pid = w.client_is();
        w.env.write_engine_state("app", r#"{"todo": 1}"#);
        // The interval is long: the round of this event comes from the new subscription of the
        // waiting client.
        w.events("app", &[ev("todo", 5)]);
        install_copy(&copy);
        let run = client.wait(10).unwrap();
        c.check("a new binary: the client connects again and gets the events once", format!("0 {} 2", ev("todo", 5)),
            format!("{} {} {}", run.code, norow(&run.out), starts_of(&w, old)));
        let sub = w.sub_of("app");
        let fresh = w.state()["engine"]["app"]["todo"].is_null();
        c.check("a new binary: the client keeps its process and its flags, not --fresh", format!("{client_pid} 600 no"),
            format!("{} {} {}", sub["client_pid"], sub["interval"], yes_no(fresh)));
        c
    })
}

fn daemon_killed() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let client = w.start(w.watch_command(&[]));
        wait_for(10, || w.has_sub("app"));
        let old = w.daemon_pid();
        kill(old, libc::SIGKILL);
        w.events("app", &[ev("todo", 7)]);
        let run = client.wait(10).unwrap();
        c.check("daemon killed: client starts it, event not lost", format!("0 {}", ev("todo", 7)),
            format!("{} {}", run.code, norow(&run.out)));
        c.check("daemon killed: new daemon", "yes", yes_no(w.daemon_pid() != old && is_daemon(w.daemon_pid())));
        c
    })
}

fn slow_check(w: &Watchd) -> support::daemon::Background {
    w.events("app", &[ev("todo", 5)]);
    w.watch(&["--interval", "600"]);
    w.fake("app", "sleep", "3\n");
    w.events("app", &[ev("todo", 6)]);
    w.clear_args();
    let client = w.start(w.watch_command(&["--interval", "600", "--once"]));
    wait_for(5, || args_written(w));
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
        c.check("daemon killed during a check: client starts it, the next check gives the event", format!("0 {}", ev("todo", 8)),
            format!("{} {}", run.code, norow(&run.out)));
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
        let run = w.watch(&[]);
        c.check("leftover socket file with no daemon: client gets events", format!("0 {}", ev("todo", 5)),
            format!("{} {}", run.code, norow(&run.out)));
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
        c.check("log over 10000 lines: the daemon keeps the last 5000", "7001", w.log().lines().next().unwrap_or_default().to_string());
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
        c.check("the daemon gets SIGTERM during a check: event not lost", format!("0 {}", ev("todo", 6)),
            format!("{} {}", run.code, norow(&run.out)));
        c.check("the daemon gets SIGTERM during a check: daemon gone", "no", yes_no(alive(pid.unwrap_or(0))));
        c
    })
}

fn once_after_poke() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let client = slow_check(&w);
        w.events("app", &[ev("todo", 7)]);
        let run = w.watch(&["--interval", "600", "--once"]);
        c.check("--once: waits for a round that starts after the poke", format!("0 {}\n{}", ev("todo", 6), ev("todo", 7)),
            format!("{} {}", run.code, norow(&run.out)));
        client.wait(10);
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
        w.watch(&[]);
        std::fs::write(&nc, "#!/bin/sh\nexit 1\n").unwrap();
        w.fake("app", "exit", "4\n");
        let client = w.start(w.watch_command(&[]));
        wait_for(5, || w.log_count("network error") > 0);
        sleep(2);
        c.check("network down: no client error, subscription stays", "running no",
            format!("{} {}", if client.running() { "running" } else { "stopped" }, w.sub_gone("app")));
        w.client(&["unsubscribe", "--repo", w.env.repo.to_str().unwrap()]);
        client.code();
        let polled = || !w.state()["repos"]["app"]["last_poll"].is_null();
        wait_for(15, || !polled());
        c.check("network down: repo loop exits when its subscriptions end", "yes", yes_no(!polled()));
        std::fs::write(&nc, "#!/bin/sh\nexit 0\n").unwrap();
        c
    })
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
fn a_new_binary_the_client_keeps_its_process_and_its_flags_not_fresh() {
    new_binary_client().assert("a new binary: the client keeps its process and its flags, not --fresh");
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
fn once_waits_for_a_round_that_starts_after_the_poke() {
    once_after_poke().assert("--once: waits for a round that starts after the poke");
}

#[test]
fn network_down_no_client_error_subscription_stays() {
    network_down().assert("network down: no client error, subscription stays");
}

#[test]
fn network_down_repo_loop_exits_when_its_subscriptions_end() {
    network_down().assert("network down: repo loop exits when its subscriptions end");
}
