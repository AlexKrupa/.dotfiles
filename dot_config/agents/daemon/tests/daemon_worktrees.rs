mod support;

use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::OnceLock;

use serde_json::{Value, json};
use support::Checks;
use support::daemon::{Watchd, end, sleep, wait_for};

fn repos(w: &Watchd) -> String {
    let path = w.watchd.join("repos.json");
    match path.exists() {
        true => support::read_json(&path)["repos"].to_string(),
        false => "[]".to_string(),
    }
}

/// A `follow` client from the folder keeps the daemon up until the end of the test.
fn follower(w: &Watchd, folder: &Path) -> Child {
    let mut command = w.command();
    command.current_dir(folder).arg("follow");
    let (child, output) = w.spawn_logged(command, "follow.out");
    wait_for(10, || std::fs::metadata(&output).is_ok_and(|meta| meta.len() > 0));
    child
}

fn sidebar_lines(w: &Watchd) -> Vec<Value> {
    let text = std::fs::read_to_string(w.env.dir.join("follow.out")).unwrap_or_default();
    text.lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|line| line["type"] == "sidebar")
        .collect()
}

const STACK: &str = r#"{"name":"main","ups":[{"name":"a"}]}
{"name":"a","down":{"name":"main"},"ups":[{"name":"b"}],"change":{"id":"!12","url":"u"}}
{"name":"b","current":true,"down":{"name":"a"}}
"#;

/// The repo has one commit and git-spice data. The linked worktree is `<dir>/wt` on branch `b`.
fn stacked_worktree(w: &Watchd) -> PathBuf {
    let wt = w.env.dir.join("wt");
    w.env.commit(&w.env.repo, "one");
    w.env
        .git(&w.env.repo, &["worktree", "add", "-q", "-b", "b", wt.to_str().unwrap()]);
    w.env.git(&w.env.repo, &["update-ref", "refs/spice/data", "HEAD"]);
    wt
}

fn spice_calls(w: &Watchd) -> usize {
    w.env.calls_with("git-spice").lines().count()
}

fn local_state() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let wt = stacked_worktree(&w);
        w.env.fake_spice(&wt, STACK);
        let follow = follower(&w, &w.env.dir);
        w.client_in(&wt, &["status"]);

        wait_for(5, || !w.worktree_state(&wt).is_null());
        let state = w.worktree_state(&wt);
        c.check(
            "local state: stack, MRs, and branch from git-spice",
            r#"["a","b"] [12] "b""#,
            format!("{} {} {}", state["stack"], state["mrs"], state["branch"]),
        );
        wait_for(5, || {
            sidebar_lines(&w)
                .last()
                .is_some_and(|line| !line["worktrees"][wt.to_str().unwrap()].is_null())
        });
        let last = sidebar_lines(&w).last().cloned().unwrap_or(Value::Null);
        c.check(
            "local state: the sidebar line has the stack of the worktree",
            2,
            last["worktrees"][wt.to_str().unwrap()]["stack"]
                .as_array()
                .map_or(0, Vec::len),
        );

        let calls = spice_calls(&w);
        sleep(3);
        c.check(
            "local state: no git-spice call with the same key",
            calls,
            spice_calls(&w),
        );

        w.env.commit(&wt, "two");
        wait_for(5, || spice_calls(&w) > calls);
        sleep(2);
        c.check(
            "local state: a commit gives one git-spice call",
            calls + 1,
            spice_calls(&w),
        );

        w.env.git(&w.env.repo, &["worktree", "remove", wt.to_str().unwrap()]);
        wait_for(5, || w.worktree_state(&wt).is_null());
        c.check(
            "local state: a removed worktree has no state",
            "null",
            w.worktree_state(&wt).to_string(),
        );
        c.check("local state: no herdr call", "false", w.herdr_called().to_string());
        end(follow);
        c
    })
}

#[test]
fn local_state_follows_git_spice() {
    for name in [
        "local state: stack, MRs, and branch from git-spice",
        "local state: the sidebar line has the stack of the worktree",
        "local state: no git-spice call with the same key",
        "local state: a commit gives one git-spice call",
        "local state: a removed worktree has no state",
        "local state: no herdr call",
    ] {
        local_state().assert(name);
    }
}

/// `PATH` with the fake programs, `git`, and the system folders, but no `git-spice`.
fn path_without_spice(w: &Watchd) -> String {
    std::fs::remove_file(w.env.dir.join("bin/git-spice")).unwrap();
    let git = Command::new("which").arg("git").output().unwrap();
    let git = PathBuf::from(String::from_utf8_lossy(&git.stdout).trim_end());
    let only_git = w.env.dir.join("git-only");
    std::fs::create_dir_all(&only_git).unwrap();
    std::os::unix::fs::symlink(&git, only_git.join("git")).unwrap();
    format!(
        "{}:{}:/usr/bin:/bin",
        w.env.dir.join("bin").display(),
        only_git.display()
    )
}

#[test]
fn local_state_without_git_spice_data() {
    let mut w = Watchd::new();
    let wt = w.env.dir.join("wt");
    w.env.commit(&w.env.repo, "one");
    w.env
        .git(&w.env.repo, &["worktree", "add", "-q", "-b", "b", wt.to_str().unwrap()]);
    let path = path_without_spice(&w);
    w.env.set_env("PATH", &path);
    let follow = follower(&w, &w.env.dir);
    w.client_in(&wt, &["status"]);

    wait_for(5, || !w.worktree_state(&wt).is_null());
    sleep(2);
    let no_data = (w.worktree_state(&wt)["stack"].to_string(), w.log_count("git-spice"));
    w.env.git(&w.env.repo, &["update-ref", "refs/spice/data", "HEAD"]);
    sleep(5);

    assert_eq!(no_data, ("[]".to_string(), 0), "no spice data: no git-spice call");
    assert_eq!(w.worktree_state(&wt)["stack"].to_string(), "[]");
    let line = format!("{}: git-spice is not installed", wt.display());
    assert_eq!(w.log_count(&line), 1, "{}", w.log());
    end(follow);
}

#[test]
fn local_state_uses_canonical_paths() {
    let w = Watchd::new();
    w.env.commit(&w.env.repo, "one");
    let canonical = w.env.dir.join("w t");
    let symlinked = PathBuf::from(canonical.to_str().unwrap().replacen("/private/", "/", 1));
    assert_ne!(symlinked, canonical, "the temp folder has a symlink");
    w.env.git(
        &w.env.repo,
        &["worktree", "add", "-q", "-b", "b", symlinked.to_str().unwrap()],
    );
    let follow = follower(&w, &w.env.dir);
    w.client_in(&symlinked, &["status"]);

    wait_for(5, || !w.worktree_state(&canonical).is_null());

    assert_eq!(w.worktree_state(&canonical)["path"], json!(canonical));
    end(follow);
}

fn client_folder() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let follow = follower(&w, &w.env.dir);
        c.check("client folder: a folder outside git adds nothing", "[]", repos(&w));

        w.client(&["status"]);
        c.check(
            "client folder: the repo of the client enters the managed set",
            json!([w.env.repo]),
            repos(&w),
        );

        std::fs::remove_dir_all(&w.env.repo).unwrap();
        wait_for(5, || repos(&w) == "[]");
        sleep(1);
        c.check("client folder: a gone repo leaves the managed set", "[]", repos(&w));
        c.check(
            "client folder: a gone repo is logged one time",
            1,
            w.log_count(&format!("repo gone: {}", w.env.repo.display())),
        );
        end(follow);
        c
    })
}

#[test]
fn client_folder_adds_the_repo() {
    client_folder().assert("client folder: a folder outside git adds nothing");
    client_folder().assert("client folder: the repo of the client enters the managed set");
}

#[test]
fn client_folder_drops_a_gone_repo() {
    client_folder().assert("client folder: a gone repo leaves the managed set");
    client_folder().assert("client folder: a gone repo is logged one time");
}

#[test]
fn daemon_start_adds_the_repo_of_each_subscription() {
    let w = Watchd::new();
    std::fs::create_dir_all(w.watchd.join("subs")).unwrap();
    let sub = json!({
        "version": 1, "key": "app", "slug": "app", "repo": w.env.repo, "mode": "hub", "mrs": [],
        "interval": 120, "session_pid": w.session_pid(), "client_pid": 1, "client_at": 0,
    });
    std::fs::write(w.watchd.join("subs/app.json"), sub.to_string()).unwrap();

    let follow = follower(&w, &w.env.dir);

    assert_eq!(repos(&w), json!([w.env.repo]).to_string());
    end(follow);
}

/// A bare origin with `main`, the managed clone `<dir>/work`, and the clone `<dir>/pusher`.
fn origin(w: &Watchd) -> (PathBuf, PathBuf) {
    let dir = &w.env.dir;
    w.env.git(dir, &["init", "-q", "--bare", "-b", "main", "origin.git"]);
    w.env.git(dir, &["clone", "-q", "origin.git", "pusher"]);
    let pusher = dir.join("pusher");
    std::fs::write(pusher.join("f"), "one\n").unwrap();
    w.env.git(&pusher, &["add", "f"]);
    push(w, &pusher, "one");
    w.env.git(dir, &["clone", "-q", "origin.git", "work"]);
    (pusher, dir.join("work"))
}

fn push(w: &Watchd, pusher: &Path, message: &str) {
    w.env.commit(pusher, message);
    w.env.git(pusher, &["push", "-q", "origin", "main"]);
}

fn head(w: &Watchd, folder: &Path) -> String {
    w.env.git(folder, &["rev-parse", "HEAD"])
}

fn pull_lines(w: &Watchd) -> usize {
    let text = std::fs::read_to_string(w.watchd.join("events.jsonl")).unwrap_or_default();
    text.lines()
        .filter(|line| line.contains(r#""kind":"pull-blocked""#))
        .count()
}

fn items(w: &Watchd, key: &str) -> String {
    let path = w.watchd.join(format!("items/{key}.json"));
    match path.exists() {
        true => {
            let items = support::read_json(&path)["items"].clone();
            let keys: Vec<String> = items
                .as_array()
                .unwrap_or(&Vec::new())
                .iter()
                .map(|item| support::raw(&item["item"]))
                .collect();
            keys.join(" ")
        }
        false => String::new(),
    }
}

fn managed_loop() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let mut w = Watchd::new();
        w.env.set_env("WATCHD_MANAGED_SECONDS", "1");
        let mut c = Checks::default();
        let (pusher, work) = origin(&w);
        let follow = follower(&w, &w.env.dir);
        w.client_in(&work, &["status"]);

        push(&w, &pusher, "two");
        wait_for(10, || head(&w, &work) == head(&w, &pusher));
        c.check(
            "managed loop: the main checkout gets the new commit of origin",
            head(&w, &pusher),
            head(&w, &work),
        );

        std::fs::write(work.join("f"), "local\n").unwrap();
        push(&w, &pusher, "three");
        wait_for(10, || pull_lines(&w) > 0);
        sleep(4);
        c.check(
            "managed loop: a blocked fast-forward is one event and one item",
            "1 pull:main",
            format!("{} {}", pull_lines(&w), items(&w, "work")),
        );

        w.env.git(&work, &["checkout", "--", "f"]);
        wait_for(10, || items(&w, "work").is_empty());
        c.check(
            "managed loop: the item closes after the fast-forward",
            format!(" {}", head(&w, &pusher)),
            format!("{} {}", items(&w, "work"), head(&w, &work)),
        );
        end(follow);
        c
    })
}

#[test]
fn managed_loop_fetches_and_fast_forwards() {
    for name in [
        "managed loop: the main checkout gets the new commit of origin",
        "managed loop: a blocked fast-forward is one event and one item",
        "managed loop: the item closes after the fast-forward",
    ] {
        managed_loop().assert(name);
    }
}

#[test]
fn managed_loop_without_origin_head() {
    let mut w = Watchd::new();
    w.env.set_env("WATCHD_MANAGED_SECONDS", "1");
    let (_, work) = origin(&w);
    w.env.git(&work, &["remote", "set-head", "origin", "-d"]);
    w.env.git(&work, &["update-ref", "refs/spice/data", "HEAD"]);
    w.env.fake_spice(&work, STACK);
    let follow = follower(&w, &w.env.dir);
    w.client_in(&work, &["status"]);

    wait_for(5, || !w.worktree_state(&work).is_null());
    sleep(4);

    assert_eq!(
        w.log_count("no default branch: origin/HEAD is not set"),
        1,
        "{}",
        w.log()
    );
    assert!(!work.join(".git/FETCH_HEAD").exists(), "no fetch");
    assert_eq!(items(&w, "work"), "");
    assert_eq!(w.worktree_state(&work)["stack"], json!(["a", "b"]));
    end(follow);
}

#[test]
fn managed_loop_waits_for_the_network() {
    let mut w = Watchd::new();
    w.env.set_env("WATCHD_MANAGED_SECONDS", "1");
    let (_, work) = origin(&w);
    w.env.git(
        &work,
        &["remote", "set-url", "origin", "https://unreachable.invalid/x.git"],
    );
    std::fs::write(w.env.dir.join("bin/nc"), "#!/bin/sh\nexit 1\n").unwrap();
    let follow = follower(&w, &w.env.dir);
    w.client_in(&work, &["status"]);

    wait_for(10, || w.log_count("network down") > 0);
    sleep(3);

    assert_eq!(w.log_count("network down"), 1, "{}", w.log());
    assert_eq!((items(&w, "work"), pull_lines(&w)), (String::new(), 0));
    end(follow);
}

#[test]
fn managed_loop_wakes_for_a_new_hub() {
    let w = Watchd::new();
    let (pusher, work) = origin(&w);
    let follow = follower(&w, &w.env.dir);
    w.client_in(&work, &["status"]);
    wait_for(5, || w.log_count("managed loop start") > 0);
    sleep(2);
    push(&w, &pusher, "two");

    let mut hub = w.watch_command(&["--once"]);
    hub.current_dir(&work);
    w.run(hub);
    wait_for(5, || head(&w, &work) == head(&w, &pusher));

    assert_eq!(head(&w, &work), head(&w, &pusher), "{}", w.log());
    end(follow);
}

#[test]
fn local_state_has_the_conflict_with_main() {
    let mut w = Watchd::new();
    w.env.set_env("WATCHD_MANAGED_SECONDS", "1");
    let (pusher, work) = origin(&w);
    let wt = w.env.dir.join("wt");
    w.env
        .git(&work, &["worktree", "add", "-q", "-b", "b", wt.to_str().unwrap()]);
    std::fs::write(wt.join("f"), "branch\n").unwrap();
    w.env.git(&wt, &["commit", "-q", "-am", "branch"]);
    let follow = follower(&w, &w.env.dir);
    w.client_in(&wt, &["status"]);
    wait_for(5, || !w.worktree_state(&wt).is_null());
    let before = w.worktree_state(&wt)["conflict"].clone();

    std::fs::write(pusher.join("f"), "main\n").unwrap();
    w.env.git(&pusher, &["commit", "-q", "-am", "main"]);
    w.env.git(&pusher, &["push", "-q", "origin", "main"]);
    wait_for(10, || w.worktree_state(&wt)["conflict"] == json!(["f"]));

    assert_eq!(before, json!([]));
    assert_eq!(w.worktree_state(&wt)["conflict"], json!(["f"]), "{}", w.log());
    end(follow);
}
