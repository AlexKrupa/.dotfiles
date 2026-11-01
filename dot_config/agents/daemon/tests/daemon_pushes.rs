mod support;

use std::path::{Path, PathBuf};

use serde_json::Value;
use support::daemon::{Watchd, wait_for};

/// A bare origin with the branch `b` of the repo, and a clone that pushes the commits of others.
fn origin(w: &Watchd) -> (PathBuf, PathBuf) {
    let env = &w.env;
    let origin = env.dir.join("origin.git");
    env.git(&env.dir, &["init", "-q", "--bare", "origin.git"]);
    env.git(&env.repo, &["remote", "set-url", "origin", origin.to_str().unwrap()]);
    env.git(&env.repo, &["switch", "-q", "-c", "b"]);
    env.commit(&env.repo, "one");
    env.git(&env.repo, &["push", "-q", "origin", "b"]);
    env.git(&env.dir, &["clone", "-q", "-b", "b", "origin.git", "pusher"]);
    (origin, env.dir.join("pusher"))
}

/// Returns the new head.
fn push_mr_head(w: &Watchd, origin: &Path, folder: &Path) -> String {
    let head = w.env.git(folder, &["rev-parse", "HEAD"]);
    w.env.git(
        folder,
        &[
            "push",
            "-q",
            "-f",
            origin.to_str().unwrap(),
            "HEAD:refs/merge-requests/5/head",
        ],
    );
    head
}

fn pushed(head: &str) -> String {
    format!(
        r#"{{"kind":"pushed","iid":5,"title":"Add foo","url":"u","actor":"","detail":"pushed","branch":"b","old_base":"b1","old_head":"h1","new_base":"b1","new_head":"{head}"}}"#
    )
}

fn has(w: &Watchd, commit: &str) -> bool {
    std::process::Command::new("git")
        .arg("-C")
        .arg(&w.env.repo)
        .args(["cat-file", "-e", commit])
        .status()
        .unwrap()
        .success()
}

fn events(run: &support::Run) -> Vec<Value> {
    run.out
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

#[test]
fn push_from_elsewhere_reaches_the_author() {
    let w = Watchd::new();
    let (origin, pusher) = origin(&w);
    w.env.commit(&pusher, "from elsewhere");
    let head = push_mr_head(&w, &origin, &pusher);
    w.events(&w.author_key(), &[pushed(&head)]);

    let run = w.watch_wait(&["--mr", "5"]);

    let events = events(&run);
    assert_eq!(events.len(), 1, "{}", run.out);
    assert_eq!(events[0]["kind"], "pushed");
    assert!(events[0].get("local").is_none(), "{}", run.out);
    assert!(has(&w, &head));
}

#[test]
fn own_push_reaches_no_author() {
    let w = Watchd::new();
    origin(&w);
    let head = w.env.git(&w.env.repo, &["rev-parse", "HEAD"]);
    let key = w.author_key();
    w.events(&key, &[pushed(&head)]);

    assert_eq!(w.watch(&["--mr", "5"]).code, 0);
    let checked = wait_for(10, || w.rounds_of(&key) >= 2);

    assert!(checked, "{}", w.log());
    assert_eq!(w.inbox_of(&key), "");
    assert_eq!(w.log_count("fetch of MR"), 0, "{}", w.log());
}

#[test]
fn failed_fetch_still_delivers_pushed() {
    let w = Watchd::new();
    let (_, pusher) = origin(&w);
    w.env.commit(&pusher, "from elsewhere");
    let head = w.env.git(&pusher, &["rev-parse", "HEAD"]);
    let review = format!("{}-review-5", w.author_key());
    w.events(&review, &[pushed(&head)]);

    let run = w.watch_wait(&["--review", "--mr", "5"]);

    let events = events(&run);
    assert_eq!(events.len(), 1, "{}", run.out);
    assert_eq!(events[0]["kind"], "pushed");
    assert_eq!(w.log_count("fetch of MR 5:"), 1, "{}", w.log());
    assert_eq!(w.log_count(" of 5:"), 0, "{}", w.log());
}
