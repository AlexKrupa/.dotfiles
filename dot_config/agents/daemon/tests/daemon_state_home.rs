mod support;

use std::path::Path;
use std::process::Stdio;

use support::Run;
use support::daemon::{Watchd, wait_for};

fn set_state_home(w: &Watchd, folder: &Path) {
    w.env
        .git(&w.env.repo, &["config", "watchd.stateHome", folder.to_str().unwrap()]);
}

fn assert_fails_and_starts_none(w: &Watchd, other: &Path, run: &Run) {
    assert_ne!(run.code, 0, "{}", run.out);
    let text = format!(
        "no watchd daemon in {}, run: daemon/sample/sample start",
        other.display()
    );
    assert!(run.err.contains(&text), "{}", run.err);
    assert!(!other.join("watchd/daemon.pid").exists());
    assert!(!w.watchd.join("daemon.pid").exists());
}

#[test]
fn client_with_state_home_and_no_daemon_fails_and_starts_none() {
    let w = Watchd::new();
    let other = w.env.dir.join("other");
    set_state_home(&w, &other);

    let run = w.client(&["kind", "mine"]);

    assert_fails_and_starts_none(&w, &other, &run);
}

#[test]
fn client_with_repo_flag_uses_the_state_home_of_that_repo() {
    let w = Watchd::new();
    let other = w.env.dir.join("other");
    set_state_home(&w, &other);
    let repo = w.env.repo.to_str().unwrap();

    let run = w.client_in(&w.env.dir, &["watch", "--once", "--repo", repo]);

    assert_fails_and_starts_none(&w, &other, &run);
}

#[test]
fn client_with_state_home_uses_that_daemon() {
    let w = Watchd::new();
    let other = w.env.dir.join("other");
    let mut daemon = w
        .command()
        .arg("daemon")
        .env("XDG_STATE_HOME", &other)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert!(wait_for(10, || other.join("watchd/daemon.sock").exists()));
    set_state_home(&w, &other);

    let run = w.client(&["kind", "mine"]);

    let repos = other.join("watchd/repos.json");
    let has_repo = wait_for(5, || {
        std::fs::read_to_string(&repos).is_ok_and(|text| text.contains(w.env.repo.to_str().unwrap()))
    });
    let _ = daemon.kill();
    let _ = daemon.wait();
    assert_eq!(run.code, 0, "{}", run.err);
    assert!(has_repo, "{}", std::fs::read_to_string(&repos).unwrap_or_default());
    assert!(!w.watchd.join("repos.json").exists());
}
