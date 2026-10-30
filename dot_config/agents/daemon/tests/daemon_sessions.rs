mod support;

use std::path::Path;
use std::process::Command;
use std::sync::OnceLock;
use std::time::Instant;

use serde_json::{Value, json};
use support::Checks;
use support::daemon::{Watchd, end, ev, norm, norow, session, sleep, wait_for};

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

fn iev(kind: &str, iid: u64, item: &str) -> String {
    json!({"kind": kind, "iid": iid, "title": "Add foo", "url": "u", "actor": "anna", "detail": "d", "branch": "b",
        "item": item})
    .to_string()
}

fn item_keys(items: &Value) -> String {
    let items = items["items"].as_array().cloned().unwrap_or_default();
    Value::from(items.iter().map(|item| item["item"].clone()).collect::<Vec<_>>()).to_string()
}

fn owner_gone_at(w: &Watchd, id: &str) -> Value {
    w.state()["sessions"][id]["owner_gone_at"].clone()
}

/// A shell that starts the command in the background and exits at once.
fn orphaned(w: &Watchd, command: Command, output: &Path) -> Command {
    let mut shell = Command::new("sh");
    shell
        .arg("-c")
        .arg(r#"program=$1; output=$2; shift 2; "$program" "$@" >"$output" 2>&1 &"#)
        .arg("sh")
        .arg(command.get_program())
        .arg(output)
        .args(command.get_args())
        .current_dir(&w.env.repo);
    for (key, value) in command.get_envs() {
        match value {
            Some(value) => shell.env(key, value),
            None => shell.env_remove(key),
        };
    }
    shell
}

fn arg_line_ends(w: &Watchd, end: &str) -> bool {
    w.args().lines().any(|line| line.ends_with(end))
}

fn leftover_error() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.events("app", &[ev("todo", 5)]);
        w.watch_wait(&[]);
        w.fake("app", "exit", "5\n");
        w.fake("app", "err", "watchd: HTTP 403 on todos\n");
        wait_for(5, || w.has_error("app"));
        let other = "session-other";
        w.events("app", &[ev("todo", 6)]);
        w.run(w.as_session(w.watch_command(&[]), other, w.session_pid()));
        let run = w.run(w.as_session(w.wait_command(), other, w.session_pid()));
        c.check(
            "leftover error does not go to a new session",
            format!("0 {}", ev("todo", 6)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        let run = w.wait();
        c.check(
            "the error of an ended record goes to the next wait of its session",
            "1 watchd: HTTP 403 on todos",
            format!("{} {}", run.code, run.err),
        );
        c
    })
}

fn review_skip() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let review = format!("{}-review-5", w.author_key());
        let repo = format!("--repo {}", w.env.repo.display());
        w.events(&review, &[ev("comment", 5)]);
        w.watch(&["--review", "--mr", "5"]);
        w.watch(&[]);
        let skip = format!("{repo} --skip-mr 5");
        wait_for(10, || arg_line_ends(&w, &skip));
        c.check(
            "review: hub gets --skip-mr for the reviewed MR",
            "yes",
            yes_no(arg_line_ends(&w, &skip)),
        );
        c
    })
}

fn all_merged() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let author = w.author_key();
        w.events(&author, &[ev("pipeline", 5)]);
        w.watch_wait(&["--mr", "5"]);
        w.events(&author, &[ev("merged", 5)]);
        wait_for(5, || !w.has_sub(&author));
        c.check("all MRs merged: subscription ends", "yes", w.sub_gone(&author));
        c.check(
            "all MRs merged: inbox waits for the client",
            norm(&ev("merged", 5)),
            w.inbox_of(&author),
        );
        let run = w.wait();
        c.check(
            "all MRs merged: the client takes the inbox",
            format!("0 {}", ev("merged", 5)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        c
    })
}

fn watch_again() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.events("app", &[ev("todo", 5)]);
        w.watch_wait(&["--interval", "600"]);
        w.events("app", &[ev("todo", 6)]);
        let started = Instant::now();
        let run = w.watch_wait(&["--interval", "600"]);
        c.check(
            "watch of a key with a record: one round now",
            format!("0 {} yes", ev("todo", 6)),
            format!(
                "{} {} {}",
                run.code,
                norow(&run.out),
                yes_no(started.elapsed().as_secs() <= 5)
            ),
        );
        c
    })
}

fn smallest_interval() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.watch(&["--interval", "600"]);
        w.watch(&["--mr", "5"]);
        let before = w.rounds_of("app");
        c.check(
            "smallest interval used",
            "yes",
            yes_no(wait_for(10, || w.rounds_of("app") - before > 1)),
        );
        c
    })
}

fn author_mrs() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let author = w.author_key();
        w.watch(&["--mr", "5"]);
        w.watch(&["--mr", "5", "--mr", "6"]);
        c.check(
            "author: a new MR list refreshes the subscription",
            "[5,6]",
            w.sub_of(&author)["mrs"].to_string(),
        );
        w.watch(&[]);
        wait_for(10, || w.rounds_of("app") >= 2);
        let repo = format!("--repo {}", w.env.repo.display());
        c.check(
            "author: hub does not skip an author MR",
            "yes no",
            format!(
                "{} {}",
                yes_no(arg_line_ends(&w, &repo)),
                yes_no(w.args().contains("--skip-mr"))
            ),
        );
        c
    })
}

#[test]
fn leftover_error_does_not_go_to_a_new_session() {
    leftover_error().assert("leftover error does not go to a new session");
}

#[test]
fn the_error_of_an_ended_record_goes_to_the_next_wait_of_its_session() {
    leftover_error().assert("the error of an ended record goes to the next wait of its session");
}

#[test]
fn review_hub_gets_skip_mr_for_the_reviewed_mr() {
    review_skip().assert("review: hub gets --skip-mr for the reviewed MR");
}

#[test]
fn all_mrs_merged_subscription_ends() {
    all_merged().assert("all MRs merged: subscription ends");
}

#[test]
fn all_mrs_merged_inbox_waits_for_the_client() {
    all_merged().assert("all MRs merged: inbox waits for the client");
}

#[test]
fn all_mrs_merged_the_client_takes_the_inbox() {
    all_merged().assert("all MRs merged: the client takes the inbox");
}

#[test]
fn watch_of_a_key_with_a_record_one_round_now() {
    watch_again().assert("watch of a key with a record: one round now");
}

#[test]
fn smallest_interval_used() {
    smallest_interval().assert("smallest interval used");
}

#[test]
fn author_a_new_mr_list_refreshes_the_subscription() {
    author_mrs().assert("author: a new MR list refreshes the subscription");
}

#[test]
fn author_hub_does_not_skip_an_author_mr() {
    author_mrs().assert("author: hub does not skip an author MR");
}

#[test]
fn a_newer_waiter_replaces_the_older_one() {
    let w = Watchd::new();
    assert_eq!(w.watch(&[]).code, 0);
    let older = w.start(w.wait_command());
    let first = wait_for(10, || w.waiting(&w.session_id()));
    let number = w.state()["waiters"][w.session_id()].clone();

    let newer = w.start(w.wait_command());
    let older = older.wait(10).expect("the older waiter exits");
    wait_for(10, || w.state()["waiters"][w.session_id()] != number);
    w.events("app", &[ev("todo", 5)]);
    let newer = newer.wait(10).expect("the newer waiter exits");

    assert!(first, "{}", w.state());
    assert_eq!((older.code, older.out.as_str(), older.err.as_str()), (0, "", ""));
    assert_eq!((newer.code, norow(&newer.out)), (0, ev("todo", 5)), "{}", newer.err);
}

#[test]
fn the_owner_ends_the_waiter_exits_0() {
    let w = Watchd::new();
    assert_eq!(w.watch(&[]).code, 0);
    let owner = session();
    let waiter = w.start(w.as_session(w.wait_command(), &w.session_id(), owner.id()));
    let connected = wait_for(10, || w.waiting(&w.session_id()));

    end(owner);
    let run = waiter.wait(5).expect("the waiter exits in 5 seconds");

    assert!(connected, "{}", w.state());
    assert_eq!((run.code, run.out.as_str(), run.err.as_str()), (0, "", ""));
}

#[test]
fn the_owner_ends_the_events_stay_in_the_inbox() {
    let w = Watchd::new();
    assert_eq!(w.watch(&[]).code, 0);
    let owner = session();
    let mut command = w.as_session(w.wait_command(), &w.session_id(), owner.id());
    command.env("WATCH_CLIENT_TICK", "5");
    let waiter = w.start(command);
    let connected = wait_for(10, || w.waiting(&w.session_id()));

    end(owner);
    w.events("app", &[ev("todo", 5)]);
    let run = waiter.wait(10).expect("the waiter exits at its tick");

    assert!(connected, "{}", w.state());
    assert_eq!((run.code, run.out.as_str(), run.err.as_str()), (0, "", ""));
    assert_eq!(w.inbox_of("app"), norm(&ev("todo", 5)));
}

#[test]
fn the_parent_of_the_waiter_ends_the_waiter_continues() {
    let w = Watchd::new();
    assert_eq!(w.watch(&[]).code, 0);
    let output = w.env.dir.join("orphan.out");

    let status = orphaned(&w, w.wait_command(), &output).status().unwrap();
    let connected = wait_for(10, || w.waiting(&w.session_id()));
    sleep(4);
    let waiting = w.waiting(&w.session_id());
    w.events("app", &[ev("todo", 5)]);
    let delivered = wait_for(10, || {
        std::fs::read_to_string(&output).is_ok_and(|text| text.ends_with('\n'))
    });

    assert!(status.success());
    assert!(connected && waiting, "{}", w.state());
    assert!(delivered, "{}", w.log());
    let text = std::fs::read_to_string(&output).unwrap();
    assert_eq!(norow(text.trim_end()), ev("todo", 5));
}

#[test]
fn the_owner_comes_back_in_the_grace_period_the_inbox_stays() {
    let mut w = Watchd::new();
    w.env.set_env("WATCHD_GRACE_SECONDS", "15");
    let id = w.session_id();
    let author = w.author_key();
    w.fake(&author, "state", r#"{"present": ["thread:d1"]}"#);
    assert_eq!(w.watch(&["--mr", "5"]).code, 0);
    let first = session();
    let waiter = w.start(w.as_session(w.wait_command(), &id, first.id()));
    wait_for(10, || w.waiting(&id));
    end(first);
    let away = wait_for(5, || !owner_gone_at(&w, &id).is_null());
    let exited = waiter.wait(5).map(|run| run.code);

    w.events(&author, &[iev("comment", 5, "thread:d1")]);
    let queued = wait_for(5, || !w.inbox_of(&author).is_empty());
    let hub = item_keys(&w.items_of("app"));
    let second = session();
    let run = w.run(w.as_session(w.wait_command(), &id, second.id()));

    assert!(away, "{}", w.state());
    assert_eq!(exited, Some(0));
    assert!(queued, "{}", w.state());
    assert_eq!(hub, "[]");
    assert_eq!(
        (run.code, norm(&norow(&run.out))),
        (0, norm(&iev("comment", 5, "thread:d1"))),
        "{}",
        run.err
    );
    assert!(w.has_sub(&author), "{}", w.log());
    assert_eq!(owner_gone_at(&w, &id), Value::Null);
    end(second);
}

#[test]
fn no_waiter_comes_back_the_records_end_after_the_grace_period() {
    let mut w = Watchd::new();
    w.env.set_env("WATCHD_GRACE_SECONDS", "2");
    let id = w.session_id();
    let author = w.author_key();
    w.fake(&author, "state", r#"{"present": ["thread:d1"]}"#);
    w.events(&author, &[iev("comment", 5, "thread:d1")]);
    assert_eq!(w.watch(&["--mr", "5"]).code, 0);
    let owner = session();
    let run = w.run(w.as_session(w.wait_command(), &id, owner.id()));

    end(owner);
    let ended = wait_for(10, || !w.has_sub(&author));

    assert_eq!(run.code, 0, "{}", run.err);
    assert!(ended, "{}", w.log());
    assert_eq!(w.state()["sessions"][&id], Value::Null);
    assert_eq!(item_keys(&w.items_of("app")), r#"["thread:d1"]"#);
}

#[test]
fn a_watch_with_no_waiter_ends_after_the_grace_period() {
    let mut w = Watchd::new();
    w.env.set_env("WATCHD_GRACE_SECONDS", "2");
    assert_eq!(w.watch(&[]).code, 0);

    let ended = wait_for(10, || !w.has_sub("app"));

    assert!(ended, "{}", w.log());
}

#[test]
fn the_worktree_is_gone_the_next_wait_gives_the_error() {
    let w = Watchd::new();
    let wt = w.env.dir.join("wt");
    w.env.commit(&w.env.repo, "one");
    w.env
        .git(&w.env.repo, &["worktree", "add", "-q", "-b", "b", wt.to_str().unwrap()]);
    let mut command = w.watch_command(&[]);
    command.current_dir(&wt);
    assert_eq!(w.run(command).code, 0);

    std::fs::remove_dir_all(&wt).unwrap();
    let ended = wait_for(10, || w.state()["subs"].as_object().is_some_and(|subs| subs.is_empty()));
    let run = w.wait();

    assert!(ended, "{}", w.log());
    assert_eq!(
        (run.code, run.err),
        (1, format!("watchd: the worktree is gone: {}", wt.display()))
    );
}

#[test]
fn unsubscribe_of_a_different_live_session_exit_1() {
    let w = Watchd::new();
    w.events("app", &[ev("todo", 5)]);
    assert_eq!(w.watch_wait(&[]).code, 0);
    let mut command = w.command();
    command.args([
        "unsubscribe",
        "--session",
        "session-other",
        "--repo",
        w.env.repo.to_str().unwrap(),
    ]);

    let run = w.run(command);

    assert_eq!(
        (run.code, run.err),
        (
            1,
            format!("watchd: the subscription app is of session {}", w.session_id())
        )
    );
    assert!(w.has_sub("app"));
}

#[test]
fn unsubscribe_of_an_away_session_exit_0() {
    let w = Watchd::new();
    assert_eq!(w.watch(&[]).code, 0);
    let mut command = w.command();
    command.args([
        "unsubscribe",
        "--session",
        "session-other",
        "--repo",
        w.env.repo.to_str().unwrap(),
    ]);

    let run = w.run(command);

    assert_eq!((run.code, run.err.as_str()), (0, ""));
    assert!(!w.has_sub("app"));
}

#[test]
fn status_prints_away_for_an_away_session() {
    let w = Watchd::new();
    assert_eq!(w.watch(&[]).code, 0);

    let status = w.client(&["status"]).out;

    let row: Vec<&str> = status.lines().filter(|line| line.starts_with("app\t")).collect();
    assert_eq!(row, ["app\thub\t-\taway\t0"], "{status}");
}
