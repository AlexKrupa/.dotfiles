mod support;

use std::sync::OnceLock;
use std::time::Instant;

use support::Checks;
use support::daemon::{Watchd, ev, norm, norow, wait_for};

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
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

fn foreign_unsubscribe() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.watch(&[]);
        let mut command = w.command();
        command.args([
            "unsubscribe",
            "--session",
            "session-other",
            "--repo",
            w.env.repo.to_str().unwrap(),
        ]);
        let run = w.run(command);
        c.check(
            "unsubscribe of a different session: exit 1, no change",
            format!("1 no watchd: the subscription app is of session {}", w.session_id()),
            format!("{} {} {}", run.code, w.sub_gone("app"), run.err),
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
fn unsubscribe_of_a_different_session_exit_1_no_change() {
    foreign_unsubscribe().assert("unsubscribe of a different session: exit 1, no change");
}

#[test]
fn author_a_new_mr_list_refreshes_the_subscription() {
    author_mrs().assert("author: a new MR list refreshes the subscription");
}

#[test]
fn author_hub_does_not_skip_an_author_mr() {
    author_mrs().assert("author: hub does not skip an author MR");
}
