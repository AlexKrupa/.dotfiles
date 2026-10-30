mod support;

use std::os::unix::process::CommandExt;
use std::sync::OnceLock;

use support::Checks;
use support::daemon::{Watchd, alive, ev, is_daemon, norow, wait_for};

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

fn hub_client() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.events("app", &[ev("todo", 5)]);
        let run = w.watch_wait(&[]);
        c.check(
            "hub: event comes out of the client, exit 0",
            format!("0 {}", ev("todo", 5)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        c.check("no daemon: client starts it", "yes", yes_no(is_daemon(w.daemon_pid())));
        let sub = w.sub_of("app");
        c.check(
            "subscription: record",
            format!("app app hub [] 1 {}", w.session_id()),
            format!(
                "{} {} {} {} {} {}",
                sub["key"].as_str().unwrap_or_default(),
                sub["slug"].as_str().unwrap_or_default(),
                sub["mode"].as_str().unwrap_or_default(),
                sub["mrs"],
                sub["interval"],
                sub["session"].as_str().unwrap_or_default()
            ),
        );

        w.events("app", &[ev("todo", 6)]);
        wait_for(5, || !w.inbox_of("app").is_empty());
        w.local_rounds(2);
        let run = w.wait();
        c.check(
            "events with no client wait in the inbox",
            format!("0 {}", ev("todo", 6)),
            format!("{} {}", run.code, norow(&run.out)),
        );

        let status = w.client(&["status"]).out;
        c.check(
            "status: daemon",
            format!("daemon {}", w.daemon_pid().unwrap_or(0)),
            status.lines().next().unwrap_or_default(),
        );
        let poll = status.lines().any(|line| {
            line.strip_prefix("app last poll ").is_some_and(|time| {
                time.len() == 8
                    && time.bytes().enumerate().all(|(index, byte)| match index {
                        2 | 5 => byte == b':',
                        _ => byte.is_ascii_digit(),
                    })
            })
        });
        c.check("status: repo loop", "yes", yes_no(poll));
        c.check(
            "status lists the subscription",
            "app\thub\t-\tlive\t0",
            status
                .lines()
                .filter(|line| line.starts_with("app\t"))
                .collect::<Vec<_>>()
                .join("\n"),
        );

        let repo = w.env.repo.to_str().unwrap().to_string();
        c.check("unsubscribe: exit 0", 0, w.unsubscribe(&["--repo", &repo]).code);
        c.check("unsubscribe removes the subscription", "yes", w.sub_gone("app"));
        c
    })
}

fn errors() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        c.check(
            "no daemon: status",
            "no daemon",
            w.client(&["status"]).out.lines().next().unwrap_or_default().to_string(),
        );
        w.events(&w.author_key(), &[ev("pipeline", 5)]);
        let other = "session-other";
        let one = w.start(w.watch_command(&[]));
        let two = w.start(w.as_session(w.watch_command(&["--mr", "5"]), other, w.session_pid()));
        one.wait(20);
        two.wait(20);
        let one = w.start(w.wait_command());
        let two = w.start(w.as_session(w.wait_command(), other, w.session_pid()));
        // A hub check with no hub record keeps no events: the event comes after the record.
        w.events("app", &[ev("todo", 5)]);
        let (one, two) = (one.wait(20).unwrap(), two.wait(20).unwrap());
        let combined = |run: &support::Run| norow(&[run.out.as_str(), run.err.as_str()].concat());
        c.check(
            "two clients at once: both get events",
            format!("{} {}", ev("todo", 5), ev("pipeline", 5)),
            format!("{} {}", combined(&one), combined(&two)),
        );
        c.check("two clients at once: one daemon", 1, w.log_count("daemon start"));
        // lsof on the lock file: pgrep also finds the daemon of a real session.
        let holders = std::process::Command::new("lsof")
            .arg("-t")
            .arg(w.watchd.join("daemon.lock"))
            .output()
            .unwrap();
        c.check(
            "two clients with no daemon: one daemon process",
            1,
            String::from_utf8_lossy(&holders.stdout).lines().count(),
        );

        w.fake("app", "exit", "4\n");
        w.events("app", &[ev("todo", 7)]);
        let run = w.watch_wait(&[]);
        c.check(
            "network error: no client error, event comes",
            format!("0 {}", ev("todo", 7)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        c.check("network error: subscription stays", "no", w.sub_gone("app"));
        c.check(
            "network error: logged, not counted",
            "1 0",
            format!("{} {}", w.log_count("network error"), w.log_count("error 1 of 5")),
        );

        w.fake("app", "exit", "5\n");
        w.fake("app", "err", "watchd: HTTP 403 on todos\n");
        let run = w.watch_wait(&[]);
        c.check(
            "HTTP 403: client exit 1 with the text",
            "1 watchd: hub watch app: HTTP 403 on todos",
            format!("{} {}", run.code, run.err),
        );
        c.check("HTTP 403: no subscription", "yes", w.sub_gone("app"));

        w.events("app", &[ev("todo", 9)]);
        w.watch_wait(&[]);
        w.fake("app", "exit", "5\n");
        wait_for(5, || w.has_error("app"));
        let run = w.wait();
        c.check(
            "HTTP 403 with no client: next client exit 1, no subscription",
            "1 watchd: hub watch app: HTTP 403 on todos yes",
            format!("{} {} {}", run.code, run.err, w.sub_gone("app")),
        );

        w.fake("app", "exit", "1\n1\n1\n1\n1\n");
        w.fake("app", "err", "watchd: boom\n");
        w.clear_args();
        let run = w.watch_wait(&[]);
        c.check(
            "5 other errors: exit 1",
            "1 watchd: hub watch app: boom",
            format!("{} {}", run.code, run.err),
        );
        let repo_args = format!("--repo {}", w.env.repo.display());
        c.check(
            "5 other errors: 5 tries",
            5,
            w.args().lines().filter(|line| line.ends_with(&repo_args)).count(),
        );
        c
    })
}

fn idle_stop() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.events("app", &[ev("todo", 5)]);
        let mut command = w.watch_command(&[]);
        command.env("WATCHD_IDLE_SECONDS", "2");
        w.run(command);
        let pid = w.daemon_pid().unwrap_or(0);
        w.unsubscribe(&["--repo", w.env.repo.to_str().unwrap()]);
        wait_for(6, || !alive(pid));
        c.check(
            "idle stop: daemon gone",
            "no yes",
            format!(
                "{} {}",
                yes_no(alive(pid)),
                yes_no(!w.watchd.join("daemon.pid").exists())
            ),
        );
        c
    })
}

fn process_group() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        // Claude Code TaskStop stops the process group of the client.
        assert_eq!(w.watch(&[]).code, 0);
        let mut command = w.wait_command();
        command
            .process_group(0)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        let mut client = command.spawn().unwrap();
        let group = client.id();
        wait_for(10, || w.waiting(&w.session_id()));
        let daemon = w.daemon_pid();
        unsafe { libc::kill(-(group as i32), libc::SIGTERM) };
        let _ = client.wait();
        w.local_rounds(2);
        c.check(
            "the process group of the client gets SIGTERM: the daemon stays",
            "yes yes",
            format!("{} {}", yes_no(is_daemon(daemon)), yes_no(!alive(group))),
        );
        c
    })
}

#[test]
fn hub_event_comes_out_of_the_client_exit_0() {
    hub_client().assert("hub: event comes out of the client, exit 0");
}

#[test]
fn no_daemon_client_starts_it() {
    hub_client().assert("no daemon: client starts it");
}

#[test]
fn subscription_record() {
    hub_client().assert("subscription: record");
}

#[test]
fn events_with_no_client_wait_in_the_inbox() {
    hub_client().assert("events with no client wait in the inbox");
}

#[test]
fn status_daemon() {
    hub_client().assert("status: daemon");
}

#[test]
fn status_repo_loop() {
    hub_client().assert("status: repo loop");
}

#[test]
fn status_lists_the_subscription() {
    hub_client().assert("status lists the subscription");
}

#[test]
fn unsubscribe_exit_0() {
    hub_client().assert("unsubscribe: exit 0");
}

#[test]
fn unsubscribe_removes_the_subscription() {
    hub_client().assert("unsubscribe removes the subscription");
}

#[test]
fn no_daemon_status() {
    errors().assert("no daemon: status");
}

#[test]
fn two_clients_at_once_both_get_events() {
    errors().assert("two clients at once: both get events");
}

#[test]
fn two_clients_at_once_one_daemon() {
    errors().assert("two clients at once: one daemon");
}

#[test]
fn two_clients_with_no_daemon_one_daemon_process() {
    errors().assert("two clients with no daemon: one daemon process");
}

#[test]
fn network_error_no_client_error_event_comes() {
    errors().assert("network error: no client error, event comes");
}

#[test]
fn network_error_subscription_stays() {
    errors().assert("network error: subscription stays");
}

#[test]
fn network_error_logged_not_counted() {
    errors().assert("network error: logged, not counted");
}

#[test]
fn http_403_client_exit_1_with_the_text() {
    errors().assert("HTTP 403: client exit 1 with the text");
}

#[test]
fn http_403_no_subscription() {
    errors().assert("HTTP 403: no subscription");
}

#[test]
fn http_403_with_no_client_next_client_exit_1_no_subscription() {
    errors().assert("HTTP 403 with no client: next client exit 1, no subscription");
}

#[test]
fn check_5_other_errors_exit_1() {
    errors().assert("5 other errors: exit 1");
}

#[test]
fn check_5_other_errors_5_tries() {
    errors().assert("5 other errors: 5 tries");
}

#[test]
fn idle_stop_daemon_gone() {
    idle_stop().assert("idle stop: daemon gone");
}

#[test]
fn the_process_group_of_the_client_gets_sigterm_the_daemon_stays() {
    process_group().assert("the process group of the client gets SIGTERM: the daemon stays");
}

const PULL_BLOCKED: &str = r#"{"kind":"pull-blocked","iid":null,"title":null,"url":"","actor":"","detail":"changes in tracked files","branch":"main","item":"pull:main"}"#;
const DEFAULT_FAILED: &str = r#"{"kind":"default-failed","iid":null,"title":null,"url":"u/-/pipelines/88","actor":"","detail":"pipeline 88 failed","branch":"main","previous":"success","item":"main-failed:main"}"#;

/// A hub record with no waiting client.
fn live_hub(w: &Watchd) {
    w.events("app", &[ev("todo", 5)]);
    assert_eq!(w.watch_wait(&[]).code, 0);
}

fn board(w: &Watchd) -> String {
    std::fs::read_to_string(w.watchd.join("items/app.board")).unwrap_or_default()
}

#[test]
fn handled_round_wakes_no_hub() {
    let w = Watchd::new();
    live_hub(&w);

    w.events("app", &[PULL_BLOCKED.to_string()]);
    let drawn = wait_for(10, || board(&w).contains("Pull blocked: changes in tracked files"));

    assert!(drawn, "{}", board(&w));
    assert_eq!(w.inbox_of("app"), "");
    assert_eq!(w.watch(&[]).code, 0);
    w.managed_rounds(2);
    assert_eq!(w.inbox_of("app"), "");
}

#[test]
fn mixed_round_gives_the_model_only_its_events() {
    let w = Watchd::new();
    live_hub(&w);
    let hub = w.start(w.wait_command());
    wait_for(5, || w.waiting(&w.session_id()));

    w.events("app", &[PULL_BLOCKED.to_string(), DEFAULT_FAILED.to_string()]);
    let run = hub.wait(10).expect("the hub client gets the events");
    let report = w.report("{}", &[]);

    assert_eq!(support::each(&run.out, "kind"), "default-failed");
    assert!(
        report.out.contains("Pull blocked: changes in tracked files"),
        "{}",
        report.out
    );
    assert!(report.out.contains("Pipeline failed"), "{}", report.out);
}

#[test]
fn board_draws_the_board_file_again_after_a_change() {
    let w = Watchd::new();
    let file = w.watchd.join("items/app.board");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let writer = std::thread::spawn(move || {
        support::daemon::sleep(2);
        let row = r#"{"n": 1, "section": "Info", "iid": null, "title": null, "url": null, "what": "first row", "result": ""}"#;
        std::fs::write(file, format!(r#"{{"time": "10:00", "rows": [{row}]}}"#)).unwrap();
    });
    let mut command = w.command();
    command.arg("board");

    let run = support::daemon::run_limited(command, &w.env.dir, 4);
    writer.join().unwrap();

    assert_eq!(run.code, 124, "{}", run.err);
    let drawn: Vec<&str> = run.out.split("\x1b[H\x1b[2J").filter(|text| !text.is_empty()).collect();
    assert_eq!(
        drawn,
        [
            "No report yet.\n",
            "\x1b[2m10:00\x1b[0m\n\n\x1b[1m\x1b[90mINFO\x1b[0m\n\x1b[1m1 \x1b[0m first row"
        ]
    );
}
