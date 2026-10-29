mod support;

use std::process::Command;
use std::sync::OnceLock;
use std::time::Instant;

use support::Checks;
use support::daemon::{Watchd, end, ev, norm, norow, run_limited, session, wait_for};

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

fn as_session(mut command: Command, pid: u32) -> Command {
    command.env("WATCH_SESSION_PID", pid.to_string());
    command
}

fn with_client_limit(mut command: Command) -> Command {
    command.env("WATCHD_CLIENT_SECONDS", "2");
    command
}

fn arg_line_ends(w: &Watchd, end: &str) -> bool {
    w.args().lines().any(|line| line.ends_with(end))
}

fn replaced_clients() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let a = w.start(w.watch_command(&[]));
        wait_for(10, || w.has_sub("app"));
        let first = w.client_is();
        let b = w.start(w.watch_command(&[]));
        c.check("new client of the same session: old client exit 3", "3", a.code());
        wait_for(5, || w.client_is() != first);
        w.events("app", &[ev("todo", 5)]);
        let run = b.wait(10).map_or((String::new(), String::new()), |run| {
            (run.code.to_string(), norow(&run.out))
        });
        c.check(
            "new client of the same session: new client gets the events",
            format!("0 {}", ev("todo", 5)),
            format!("{} {}", run.0, run.1),
        );

        let first = w.client_is();
        let a = w.start(w.watch_command(&[]));
        wait_for(10, || w.client_is() != first);
        let other = session();
        let b = w.start(as_session(w.watch_command(&[]), other.id()));
        c.check("new session takes the key: old session client exit 3", "3", a.code());
        let started = Instant::now();
        let a = w.start(w.watch_command(&[]));
        let code = a.code();
        c.check(
            "new session takes the key: old session client exit 3 at once",
            "3 yes",
            format!("{code} {}", yes_no(started.elapsed().as_secs() <= 3)),
        );
        c.check(
            "new session takes the key: replaced sessions",
            format!("[{}]", w.session_pid()),
            w.sub_of("app")["replaced_sessions"].to_string(),
        );
        w.events("app", &[ev("todo", 6)]);
        b.code();
        end(other);
        c
    })
}

fn client_limit() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.events("app", &[ev("todo", 5)]);
        w.run(with_client_limit(w.watch_command(&[])));
        wait_for(8, || !w.has_sub("app"));
        c.check("no client for the limit: subscription ends", "yes", w.sub_gone("app"));
        c
    })
}

fn client_limit_inbox() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.events("app", &[ev("todo", 5)]);
        w.run(with_client_limit(w.watch_command(&[])));
        w.events("app", &[ev("todo", 6)]);
        wait_for(5, || !w.inbox_of("app").is_empty());
        wait_for(8, || !w.has_sub("app"));
        c.check(
            "no client for the limit: the inbox stays",
            norm(&ev("todo", 6)),
            w.inbox_of("app"),
        );
        let run = w.watch(&[]);
        c.check(
            "no client for the limit: the inbox comes at the next client of the same session",
            format!("0 {}", ev("todo", 6)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        c
    })
}

fn leftover_error() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.events("app", &[ev("todo", 5)]);
        w.watch(&[]);
        w.fake("app", "exit", "5\n");
        w.fake("app", "err", "watchd: HTTP 403 on todos\n");
        wait_for(5, || w.has_error("app"));
        let other = session();
        w.events("app", &[ev("todo", 6)]);
        let run = w.run(as_session(w.watch_command(&[]), other.id()));
        c.check(
            "leftover error does not go to a new session",
            format!("0 {}", ev("todo", 6)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        w.fake("app", "exit", "5\n");
        wait_for(5, || w.has_error("app"));
        end(other);
        wait_for(5, || !w.has_error("app"));
        c.check(
            "leftover of a dead session: removed",
            "yes",
            yes_no(!w.has_error("app")),
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
        w.run(with_client_limit(w.watch_command(&["--review", "--mr", "5"])));
        let hub = w.start(w.watch_command(&[]));
        let skip = format!("{repo} --skip-mr 5");
        wait_for(10, || arg_line_ends(&w, &skip));
        c.check(
            "review: hub gets --skip-mr for the reviewed MR",
            "yes",
            yes_no(arg_line_ends(&w, &skip)),
        );
        wait_for(8, || !w.has_sub(&review));
        c.check(
            "no client for the limit: review subscription ends",
            "yes",
            w.sub_gone(&review),
        );
        w.events("app", &[ev("todo", 7)]);
        hub.code();
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
        w.watch(&["--mr", "5"]);
        w.events(&author, &[ev("merged", 5)]);
        wait_for(5, || !w.has_sub(&author));
        c.check("all MRs merged: subscription ends", "yes", w.sub_gone(&author));
        c.check(
            "all MRs merged: inbox waits for the client",
            norm(&ev("merged", 5)),
            w.inbox_of(&author),
        );
        let run = w.watch(&["--mr", "5"]);
        c.check(
            "all MRs merged: the client takes the inbox",
            format!("0 {}", ev("merged", 5)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        c.check(
            "all MRs merged: the client does not subscribe again",
            "yes",
            w.sub_gone(&author),
        );
        c
    })
}

fn once() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.events("app", &[ev("todo", 5)]);
        w.watch(&["--interval", "600"]);
        let started = Instant::now();
        let run = run_limited(w.watch_command(&["--interval", "600", "--once"]), &w.env.dir, 5);
        c.check(
            "--once: one round now, exit 0",
            "0  yes",
            format!("{} {} {}", run.code, run.out, yes_no(started.elapsed().as_secs() <= 5)),
        );
        w.events("app", &[ev("todo", 6)]);
        let run = run_limited(w.watch_command(&["--interval", "600", "--once"]), &w.env.dir, 5);
        c.check(
            "--once: events of the round",
            format!("0 {}", ev("todo", 6)),
            format!("{} {}", run.code, norow(&run.out)),
        );
        c
    })
}

fn smallest_interval() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.events("app", &[ev("todo", 5)]);
        w.watch(&["--interval", "600"]);
        w.events(&w.author_key(), &[ev("pipeline", 5)]);
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

fn foreign_unsubscribe() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.events("app", &[ev("todo", 5)]);
        w.watch(&[]);
        let other = session();
        let mut command = w.command();
        command.args(["unsubscribe", "--repo", w.env.repo.to_str().unwrap()]);
        let run = w.run(as_session(command, other.id()));
        c.check(
            "unsubscribe of a different session: exit 1, no change",
            format!("1 no watchd: the subscription app is of session {}", w.session_pid()),
            format!("{} {} {}", run.code, w.sub_gone("app"), run.err),
        );
        end(other);
        c
    })
}

fn author_mrs() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let author = w.author_key();
        w.events(&author, &[ev("pipeline", 5)]);
        w.watch(&["--mr", "5"]);
        w.events(&author, &[ev("pipeline", 6)]);
        w.watch(&["--mr", "5", "--mr", "6"]);
        c.check(
            "author: a new MR list refreshes the subscription",
            "[5,6]",
            w.sub_of(&author)["mrs"].to_string(),
        );
        let hub = w.start(w.watch_command(&[]));
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
        w.events("app", &[ev("todo", 5)]);
        hub.code();
        c
    })
}

#[test]
fn new_client_of_the_same_session_old_client_exit_3() {
    replaced_clients().assert("new client of the same session: old client exit 3");
}

#[test]
fn new_client_of_the_same_session_new_client_gets_the_events() {
    replaced_clients().assert("new client of the same session: new client gets the events");
}

#[test]
fn new_session_takes_the_key_old_session_client_exit_3() {
    replaced_clients().assert("new session takes the key: old session client exit 3");
}

#[test]
fn new_session_takes_the_key_old_session_client_exit_3_at_once() {
    replaced_clients().assert("new session takes the key: old session client exit 3 at once");
}

#[test]
fn new_session_takes_the_key_replaced_sessions() {
    replaced_clients().assert("new session takes the key: replaced sessions");
}

#[test]
fn no_client_for_the_limit_subscription_ends() {
    client_limit().assert("no client for the limit: subscription ends");
}

#[test]
fn no_client_for_the_limit_the_inbox_stays() {
    client_limit_inbox().assert("no client for the limit: the inbox stays");
}

#[test]
fn no_client_for_the_limit_the_inbox_comes_at_the_next_client_of_the_same_session() {
    client_limit_inbox().assert("no client for the limit: the inbox comes at the next client of the same session");
}

#[test]
fn leftover_error_does_not_go_to_a_new_session() {
    leftover_error().assert("leftover error does not go to a new session");
}

#[test]
fn leftover_of_a_dead_session_removed() {
    leftover_error().assert("leftover of a dead session: removed");
}

#[test]
fn review_hub_gets_skip_mr_for_the_reviewed_mr() {
    review_skip().assert("review: hub gets --skip-mr for the reviewed MR");
}

#[test]
fn no_client_for_the_limit_review_subscription_ends() {
    review_skip().assert("no client for the limit: review subscription ends");
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
fn all_mrs_merged_the_client_does_not_subscribe_again() {
    all_merged().assert("all MRs merged: the client does not subscribe again");
}

#[test]
fn once_one_round_now_exit_0() {
    once().assert("--once: one round now, exit 0");
}

#[test]
fn once_events_of_the_round() {
    once().assert("--once: events of the round");
}

#[test]
fn smallest_interval_used() {
    smallest_interval().assert("smallest interval used");
}

#[test]
fn unsubscribe_of_a_different_session_exit_1_no_change() {
    foreign_unsubscribe().assert("unsubscribe of a different session: exit 1, no change");
}

#[test]
fn author_a_new_mr_list_refreshes_the_subscription() {
    author_mrs().assert("author: a new MR list refreshes the subscription");
}

#[test]
fn author_hub_does_not_skip_a_stack_mr() {
    author_mrs().assert("author: hub does not skip an author MR");
}
