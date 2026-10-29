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
        let follow = w.follower(&w.env.dir);
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
        w.local_rounds(2);
        c.check(
            "local state: no git-spice call with the same key",
            calls,
            spice_calls(&w),
        );

        w.env.commit(&wt, "two");
        wait_for(5, || spice_calls(&w) > calls);
        w.local_rounds(2);
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
    let follow = w.follower(&w.env.dir);
    w.client_in(&wt, &["status"]);

    wait_for(5, || !w.worktree_state(&wt).is_null());
    w.local_rounds(2);
    let no_data = (w.worktree_state(&wt)["stack"].to_string(), w.log_count("git-spice"));
    w.env.git(&w.env.repo, &["update-ref", "refs/spice/data", "HEAD"]);
    w.local_rounds(2);

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
    let follow = w.follower(&w.env.dir);
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
        let follow = w.follower(&w.env.dir);
        c.check("client folder: a folder outside git adds nothing", "[]", repos(&w));

        w.client(&["status"]);
        c.check(
            "client folder: the repo of the client enters the managed set",
            json!([w.env.repo]),
            repos(&w),
        );

        std::fs::remove_dir_all(&w.env.repo).unwrap();
        wait_for(5, || repos(&w) == "[]");
        w.local_rounds(2);
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

    let follow = w.follower(&w.env.dir);

    assert_eq!(repos(&w), json!([w.env.repo]).to_string());
    end(follow);
}

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
        w.env.set_env("WATCHD_MANAGED_SECONDS", "0.2");
        let mut c = Checks::default();
        let (pusher, work) = origin(&w);
        let follow = w.follower(&w.env.dir);
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
        w.managed_rounds(2);
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
    w.env.set_env("WATCHD_MANAGED_SECONDS", "0.2");
    let (_, work) = origin(&w);
    w.env.git(&work, &["remote", "set-head", "origin", "-d"]);
    w.env.git(&work, &["update-ref", "refs/spice/data", "HEAD"]);
    w.env.fake_spice(&work, STACK);
    let follow = w.follower(&w.env.dir);
    w.client_in(&work, &["status"]);

    wait_for(5, || !w.worktree_state(&work).is_null());
    w.managed_rounds(2);

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
    w.env.set_env("WATCHD_MANAGED_SECONDS", "0.2");
    let (_, work) = origin(&w);
    w.env.git(
        &work,
        &["remote", "set-url", "origin", "https://unreachable.invalid/x.git"],
    );
    std::fs::write(w.env.dir.join("bin/nc"), "#!/bin/sh\nexit 1\n").unwrap();
    let follow = w.follower(&w.env.dir);
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
    let follow = w.follower(&w.env.dir);
    w.client_in(&work, &["status"]);
    wait_for(5, || w.log_count("round done:") > 0);
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
    w.env.set_env("WATCHD_MANAGED_SECONDS", "0.2");
    let (pusher, work) = origin(&w);
    let wt = w.env.dir.join("wt");
    w.env
        .git(&work, &["worktree", "add", "-q", "-b", "b", wt.to_str().unwrap()]);
    std::fs::write(wt.join("f"), "branch\n").unwrap();
    w.env.git(&wt, &["commit", "-q", "-am", "branch"]);
    let follow = w.follower(&w.env.dir);
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

fn commit_f(w: &Watchd, folder: &Path, text: &str) {
    std::fs::write(folder.join("f"), text).unwrap();
    w.env.git(folder, &["commit", "-q", "-am", text]);
}

const LOWER_AND_UPPER: &str = r#"{"name":"main","ups":[{"name":"lower"}]}
{"name":"lower","down":{"name":"main"},"ups":[{"name":"upper"}],"change":{"id":"!12","url":"u"}}
{"name":"upper","current":true,"down":{"name":"lower"},"change":{"id":"!13","url":"u"}}
"#;

#[test]
fn merged_lower_branch_leaves_the_conflict_test() {
    let mut w = Watchd::new();
    w.env.set_env("WATCHD_MANAGED_SECONDS", "0.2");
    let (pusher, work) = origin(&w);
    commit_f(&w, &pusher, "1\n2\n3\n4\n5\n");
    w.env.git(&pusher, &["push", "-q", "origin", "main"]);
    w.env.git(&work, &["pull", "-q"]);
    let wt = w.env.dir.join("wt");
    w.env
        .git(&work, &["worktree", "add", "-q", "-b", "lower", wt.to_str().unwrap()]);
    commit_f(&w, &wt, "1\nB\n3\n4\n5\n");
    w.env.git(&wt, &["switch", "-q", "-c", "upper"]);
    commit_f(&w, &wt, "1\nB\n3\n4\nE\n");
    w.env.git(&work, &["update-ref", "refs/spice/data", "HEAD"]);
    w.env.fake_spice(&wt, LOWER_AND_UPPER);
    commit_f(&w, &pusher, "A\n2\n3\n4\n5\n");
    commit_f(&w, &pusher, "A\nB\n3\n4\n5\n");
    w.env.git(&pusher, &["push", "-q", "origin", "main"]);
    let follow = w.follower(&w.env.dir);
    w.client_in(&wt, &["status"]);
    wait_for(10, || w.worktree_state(&wt)["conflict"] == json!(["f"]));
    let before = w.worktree_state(&wt)["conflict"].clone();

    let merged = r#"{"kind":"merged","iid":12,"title":"T","url":"u","actor":"anna","detail":"d","branch":"lower"}"#;
    w.events(&format!("work-{}", support::hash12(&wt)), &[merged.to_string()]);
    wait_for(10, || w.worktree_state(&wt)["conflict"] == json!([]));

    assert_eq!(before, json!(["f"]), "{}", w.log());
    assert_eq!(w.worktree_state(&wt)["conflict"], json!([]), "{}", w.log());
    end(follow);
}

#[test]
fn merged_branch_of_a_lookup_leaves_the_conflict_test() {
    let mut w = Watchd::new();
    w.env.set_env("WATCHD_MANAGED_SECONDS", "0.2");
    let (pusher, work) = origin(&w);
    let wb = w.env.dir.join("wb");
    w.env
        .git(&work, &["worktree", "add", "-q", "-b", "b", wb.to_str().unwrap()]);
    commit_f(&w, &wb, "branch\n");
    commit_f(&w, &pusher, "main\n");
    w.env.git(&pusher, &["push", "-q", "origin", "main"]);
    std::fs::write(w.events.join("lookup-b"), "20\n").unwrap();
    let follow = w.follower(&w.env.dir);
    w.client_in(&wb, &["status"]);
    wait_for(10, || {
        w.worktree_state(&wb)["conflict"] == json!(["f"]) && reviews(&w) != json!([])
    });
    let before = w.worktree_state(&wb)["conflict"].clone();

    let key = format!("work-{}-review-20", support::hash12(&wb));
    w.events(&key, &[support::daemon::ev("merged", 20)]);
    wait_for(10, || w.worktree_state(&wb)["conflict"] == json!([]));

    assert_eq!(before, json!(["f"]), "{}", w.log());
    assert_eq!(w.worktree_state(&wb)["conflict"], json!([]), "{}", w.log());
    end(follow);
}

fn mr_lines(w: &Watchd, iid: u64) -> usize {
    let flag = format!("--mr {iid}");
    w.args().lines().filter(|line| line.contains(&flag)).count()
}

fn polled_worktree(w: &mut Watchd) -> (PathBuf, Child) {
    w.env.set_env("WATCHD_MANAGED_SECONDS", "0.2");
    let wt = stacked_worktree(w);
    w.env.fake_spice(&wt, STACK);
    let follow = w.follower(&w.env.dir);
    w.client_in(&wt, &["status"]);
    (wt, follow)
}

#[test]
fn polls_without_an_agent() {
    let mut w = Watchd::new();
    let (wt, follow) = polled_worktree(&mut w);

    wait_for(10, || mr_lines(&w, 12) > 0);

    let line = format!("--repo {} --mr 12", wt.display());
    assert!(w.args().lines().any(|args| args == line), "{}", w.args());
    end(follow);
}

#[test]
fn polling_of_a_worktree_stops_after_merge() {
    let mut w = Watchd::new();
    let (wt, follow) = polled_worktree(&mut w);
    let key = format!("app-{}", support::hash12(&wt));
    wait_for(10, || mr_lines(&w, 12) > 0);

    w.events(&key, &[support::daemon::ev("merged", 12)]);
    wait_for(10, || w.worktree_state(&wt)["ended"] == json!([12]));
    w.managed_rounds(1);
    w.clear_args();
    w.managed_rounds(1);

    assert_eq!(mr_lines(&w, 12), 0, "{}", w.args());
    let key = w.worktree_state(&wt)["key"].clone();
    w.env.commit(&wt, "two");
    wait_for(5, || w.worktree_state(&wt)["key"] != key);
    assert_eq!(
        w.worktree_state(&wt)["ended"],
        json!([12]),
        "a new key keeps the ended MRs"
    );
    end(follow);
}

#[test]
fn poke_of_a_key_with_no_target_ends_with_the_round() {
    let w = Watchd::new();
    let wt = stacked_worktree(&w);
    w.env.fake_spice(&wt, STACK);
    let follow = w.follower(&w.env.dir);
    w.client_in(&wt, &["status"]);
    wait_for(5, || !w.worktree_state(&wt).is_null());

    let run = w.watch(&["--interval", "600", "--once", "--mr", "12"]);
    let rounds = w.log_count("round done");
    w.local_rounds(3);

    assert_eq!(run.code, 0, "{}", run.err);
    assert!(w.log_count("round done") <= rounds + 1, "{}", w.log_count("round done"));
    end(follow);
}

fn comment(iid: u64, item: &str) -> String {
    let line = support::daemon::ev("comment", iid);
    format!("{},\"item\":\"{item}\"}}", &line[..line.len() - 1])
}

fn hub_items() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let mut w = Watchd::new();
        let mut c = Checks::default();
        let (wt, follow) = polled_worktree(&mut w);
        let key = format!("app-{}", support::hash12(&wt));
        wait_for(10, || mr_lines(&w, 12) > 0);

        w.events(&key, &[comment(12, "comment:1")]);
        wait_for(10, || items(&w, "app") == "comment:1");
        let logged = std::fs::read_to_string(w.watchd.join("events.jsonl")).unwrap_or_default();
        c.check(
            "no agent: the event of a worktree is a hub item, not a hub inbox line",
            "comment:1 [] 1",
            format!(
                "{} [{}] {}",
                items(&w, "app"),
                w.inbox_of("app"),
                logged.lines().filter(|line| line.contains(&key)).count()
            ),
        );

        let routed = w.log_count("routed 1 event");
        w.events(&key, &[comment(12, "comment:1")]);
        wait_for(10, || w.log_count("routed 1 event") > routed);
        w.managed_rounds(1);
        c.check(
            "no agent: the same item again is one hub item",
            "comment:1",
            items(&w, "app"),
        );

        let run = w.watch(&[]);
        c.check(
            "new hub: the open items come first",
            "0 comment:1",
            format!("{} {}", run.code, support::each(&run.out, "item")),
        );

        let client = w.client_is();
        let hub = w.start(w.watch_command(&[]));
        wait_for(5, || w.client_is() != client);
        w.events(&key, &[comment(12, "comment:2")]);
        let board = || std::fs::read_to_string(w.watchd.join("items/app.board")).unwrap_or_default();
        let drawn = wait_for(10, || board().contains(r#"@anna: "d""#));
        c.check(
            "live hub: the item of a worktree with no agent goes to the board, not to the hub",
            "true true",
            format!("{drawn} {}", hub.running()),
        );

        w.events(&key, &[support::daemon::ev("approved", 12)]);
        w.managed_rounds(2);
        c.check(
            "live hub: an event of a worktree with no agent and no item goes nowhere",
            "true false",
            format!("{} {}", hub.running(), board().contains("approved")),
        );
        w.events("app", &[support::daemon::ev("todo", 12)]);
        hub.wait(10);
        end(follow);
        c
    })
}

#[test]
fn events_of_a_worktree_without_agent_become_hub_items() {
    hub_items().assert("no agent: the event of a worktree is a hub item, not a hub inbox line");
}

#[test]
fn new_hub_gets_the_open_items_first() {
    hub_items().assert("new hub: the open items come first");
}

#[test]
fn same_item_of_a_worktree_without_agent_is_one_hub_item() {
    hub_items().assert("no agent: the same item again is one hub item");
}

#[test]
fn live_hub_gets_no_event_of_a_worktree_without_agent_and_item() {
    hub_items().assert("live hub: an event of a worktree with no agent and no item goes nowhere");
}

#[test]
fn board_gets_the_items_of_a_worktree_without_agent() {
    hub_items().assert("live hub: the item of a worktree with no agent goes to the board, not to the hub");
}

#[test]
fn no_live_hub_no_routing() {
    let mut w = Watchd::new();
    let (wt, follow) = polled_worktree(&mut w);
    let key = format!("app-{}", support::hash12(&wt));
    wait_for(10, || mr_lines(&w, 12) > 0);

    w.events(&key, &[comment(12, "comment:1")]);
    wait_for(10, || items(&w, "app") == "comment:1");

    assert_eq!(items(&w, "app"), "comment:1");
    assert!(!w.watchd.join("items/app.board").exists());
    end(follow);
}

const TWO_MRS: &str = r#"{"name":"main","ups":[{"name":"a"}]}
{"name":"a","down":{"name":"main"},"ups":[{"name":"b"}],"change":{"id":"!12","url":"u"}}
{"name":"b","current":true,"down":{"name":"a"},"change":{"id":"!13","url":"u"}}
"#;

fn pipeline(iid: u64) -> String {
    support::daemon::ev("pipeline", iid)
}

fn worktree_agents() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let mut w = Watchd::new();
        let mut c = Checks::default();
        w.env.set_env("WATCHD_MANAGED_SECONDS", "0.2");
        let wt = stacked_worktree(&w);
        w.env.fake_spice(&wt, TWO_MRS);
        let follow = w.follower(&w.env.dir);
        w.client_in(&wt, &["status"]);
        let key = format!("app-{}", support::hash12(&wt));
        let in_wt = |args: &[&str]| {
            let mut command = w.watch_command(args);
            command.current_dir(&wt);
            command
        };
        let after_record = |args: &[&str], lines: &[String]| {
            let agent = w.start(in_wt(args));
            wait_for(10, || w.has_sub(&key));
            w.events(&key, lines);
            agent.wait(15).map_or("timeout".to_string(), |run| {
                format!("{} {}", run.code, support::each(&run.out, "iid"))
            })
        };

        c.check(
            "linked worktree: a watch with no --mr gets the events of all its MRs",
            "0 12 13",
            after_record(&[], &[pipeline(12), pipeline(13)]),
        );
        c.check(
            "linked worktree: --mr is a filter on the events",
            "0 13",
            after_record(&["--mr", "13"], &[pipeline(12), pipeline(13)]),
        );
        c.check(
            "old watch command: --interval 1 --mr 12 gets the MR 12 event",
            "0 12",
            after_record(&["--mr", "12"], &[pipeline(12)]),
        );
        end(follow);
        c
    })
}

#[test]
fn watch_in_a_linked_worktree_waits_for_its_mrs() {
    worktree_agents().assert("linked worktree: a watch with no --mr gets the events of all its MRs");
    worktree_agents().assert("linked worktree: --mr is a filter on the events");
}

#[test]
fn old_watch_command_with_mr_still_works() {
    worktree_agents().assert("old watch command: --interval 1 --mr 12 gets the MR 12 event");
}

#[test]
fn worktree_with_no_agent_keeps_the_needs_of_its_check() {
    let mut w = Watchd::new();
    w.env.set_env("WATCHD_MANAGED_SECONDS", "0.2");
    let wt = stacked_worktree(&w);
    w.env.fake_spice(&wt, STACK);
    let key = format!("app-{}", support::hash12(&wt));
    w.fake(&key, "state", r#"{"needs": ["failed"], "present": []}"#);
    let follow = w.follower(&w.env.dir);
    w.client_in(&wt, &["status"]);

    let expected = json!({key.as_str(): ["failed"]});
    let found = wait_for(10, || w.worktree_state(&wt)["needs"] == expected);
    end(follow);

    assert!(found, "{}", w.worktree_state(&wt));
    let sidebar = sidebar_lines(&w).pop().unwrap_or_default();
    assert_eq!(sidebar["worktrees"][wt.to_str().unwrap()]["needs"], expected);
}

#[test]
fn worktree_whose_mrs_go_away_loses_their_needs() {
    let mut w = Watchd::new();
    w.env.set_env("WATCHD_MANAGED_SECONDS", "0.2");
    let wt = stacked_worktree(&w);
    w.env.fake_spice(&wt, STACK);
    let key = format!("app-{}", support::hash12(&wt));
    w.fake(&key, "state", r#"{"needs": ["ready"], "present": []}"#);
    let follow = w.follower(&w.env.dir);
    w.client_in(&wt, &["status"]);
    let found = wait_for(10, || !w.worktree_state(&wt)["needs"].is_null());

    w.env
        .fake_spice(&wt, &STACK.replace(r#","change":{"id":"!12","url":"u"}"#, ""));
    w.env.commit(&w.env.repo, "two");
    w.env.git(&w.env.repo, &["update-ref", "refs/spice/data", "HEAD"]);
    let gone = wait_for(10, || w.worktree_state(&wt)["needs"].is_null());
    end(follow);

    assert!(found, "no needs at the start: {}", w.worktree_state(&wt));
    assert!(gone, "{}", w.worktree_state(&wt));
}

#[test]
fn watch_with_no_mr_in_the_main_checkout_on_a_feature_branch_is_a_stack_watch() {
    let w = Watchd::new();
    w.env.commit(&w.env.repo, "one");
    w.env
        .git(&w.env.repo, &["update-ref", "refs/remotes/origin/main", "HEAD"]);
    w.env.git(
        &w.env.repo,
        &["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"],
    );
    w.env.git(&w.env.repo, &["switch", "-q", "-c", "feature"]);

    let _agent = w.start(w.watch_command(&[]));
    let author = wait_for(10, || w.has_sub(&w.author_key()));

    assert!(author, "no author record of the main checkout: {}", w.log());
    assert!(!w.has_sub("app"), "a hub record of the main checkout");
}

fn reviews(w: &Watchd) -> Value {
    let path = w.watchd.join("reviews.json");
    match path.exists() {
        true => support::read_json(&path)["reviews"].clone(),
        false => json!([]),
    }
}

fn review_worktree(w: &Watchd, name: &str) -> PathBuf {
    let folder = w.env.dir.join(name);
    w.env.commit(&w.env.repo, "one");
    w.env.git(
        &w.env.repo,
        &["worktree", "add", "-q", "-b", name, folder.to_str().unwrap()],
    );
    folder
}

#[test]
fn review_link_stays_after_the_agent_ends() {
    let mut w = Watchd::new();
    w.env.set_env("WATCHD_MANAGED_SECONDS", "0.2");
    let wr = review_worktree(&w, "r");
    let follow = w.follower(&w.env.dir);
    let key = format!("app-{}-review-20", support::hash12(&wr));
    let other = support::daemon::session();
    let mut agent = w.watch_command(&["--review", "--mr", "20", "--once"]);
    agent.current_dir(&wr).env("WATCH_SESSION_PID", other.id().to_string());
    w.run(agent);
    let linked = reviews(&w);

    end(other);
    wait_for(10, || !w.has_sub(&key));
    w.clear_args();
    let line = format!("--repo {} --review --mr 20", wr.display());
    let polled = wait_for(10, || w.args().lines().any(|args| args == line));
    w.events(&key, &[support::daemon::ev("merged", 20)]);
    wait_for(10, || reviews(&w) == json!([]));

    assert_eq!(linked, json!([{"worktree": wr, "iid": 20}]));
    assert!(polled, "{}", w.args());
    assert_eq!(reviews(&w), json!([]), "a merged MR ends its link");
    end(follow);
}

#[test]
fn lookup_links_a_worktree_with_no_mr() {
    let mut w = Watchd::new();
    w.env.set_env("WATCHD_MANAGED_SECONDS", "0.2");
    let wb = review_worktree(&w, "b");
    std::fs::write(w.events.join("lookup-b"), "20\n").unwrap();
    let follow = w.follower(&w.env.dir);
    w.client_in(&wb, &["status"]);

    wait_for(10, || reviews(&w) != json!([]));
    w.managed_rounds(2);

    assert_eq!(reviews(&w), json!([{"worktree": wb, "iid": 20}]));
    let line = format!("--repo {} --review --mr 20", wb.display());
    assert!(w.args().lines().any(|args| args == line), "{}", w.args());
    assert_eq!(
        w.args().lines().filter(|args| *args == "lookup b").count(),
        1,
        "{}",
        w.args()
    );
    end(follow);
}

#[test]
fn follow_client_from_a_repo_adds_no_repo() {
    let w = Watchd::new();

    let follow = w.follower(&w.env.repo);
    w.local_rounds(2);

    assert_eq!(repos(&w), "[]");
    end(follow);
}

#[test]
fn kind_is_kept_by_worktree_path() {
    let w = Watchd::new();
    let wt = stacked_worktree(&w);
    let follow = w.follower(&w.env.dir);

    let run = w.client_in(&wt, &["kind", "review"]);
    wait_for(5, || {
        sidebar_lines(&w)
            .last()
            .is_some_and(|line| line["worktrees"][wt.to_str().unwrap()]["kind"] == "review")
    });

    assert_eq!(run.code, 0, "{}", run.err);
    assert_eq!(w.worktree_state(&wt)["kind"], "review");
    let last = sidebar_lines(&w).last().cloned().unwrap_or(Value::Null);
    assert_eq!(last["worktrees"][wt.to_str().unwrap()]["kind"], "review");
    assert!(last.get("workspaces").is_none(), "{last}");
    end(follow);
}

#[test]
fn kind_hub_opens_the_board() {
    let w = Watchd::new();
    let calls = || std::fs::read_to_string(w.workspaces().join("calls")).unwrap_or_default();

    let mine = w.client_in(&w.env.repo, &["kind", "mine"]);
    let after_mine = calls();
    let hub = w.client_in(&w.env.repo, &["kind", "hub"]);

    assert_eq!((mine.code, hub.code), (0, 0), "{}{}", mine.err, hub.err);
    assert_eq!(after_mine, "");
    let repo = w.env.repo.canonicalize().unwrap();
    assert_eq!(calls(), format!("open_board {}\n", repo.display()));
}

#[test]
fn local_round_keeps_a_kind_set_during_the_round() {
    let w = Watchd::new();
    let wt = stacked_worktree(&w);
    w.env.fake_spice(&wt, STACK);
    let follow = w.follower(&w.env.dir);
    w.client_in(&wt, &["status"]);
    wait_for(5, || !w.worktree_state(&wt)["key"].as_str().unwrap_or("").is_empty());
    std::fs::write(w.env.mock.join("spice-sleep"), "3").unwrap();
    let calls = spice_calls(&w);

    w.env.commit(&wt, "two");
    wait_for(5, || spice_calls(&w) > calls);
    let run = w.client_in(&wt, &["kind", "review"]);
    w.local_rounds(1);

    assert_eq!(run.code, 0, "{}", run.err);
    assert_eq!(w.worktree_state(&wt)["kind"], "review", "{}", w.worktree_state(&wt));
    end(follow);
}
