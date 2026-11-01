mod support;

use std::path::Path;
use std::process::Command;
use std::sync::OnceLock;

use serde_json::{Value, json};
use support::daemon::{Watchd, end, norow, session, wait_for};
use support::{Checks, URL};

fn gql(w: &Watchd, iid: u64, change: impl FnOnce(&mut Value)) {
    let mut mr = json!({"iid": iid.to_string(), "title": "Add foo", "webUrl": format!("{URL}/{iid}"),
        "sourceBranch": "ABC-1/foo", "state": "opened", "draft": false, "mergeUser": null, "headPipeline": null,
        "approvedBy": {"nodes": []}, "detailedMergeStatus": "NOT_APPROVED", "conflicts": false, "mergeable": false});
    change(&mut mr);
    let response = json!({"data": {"currentUser": {"username": "me"}, "project": {"mergeRequest": mr}}});
    w.env.fixture(&format!("gql_{iid}"), &response.to_string());
}

fn anna_note(id: u64) -> Value {
    json!({"id": id, "body": "Why?", "system": false, "author": {"username": "anna"}, "position": null,
        "resolvable": true, "resolved": false, "resolved_by": null})
}

fn commented(updated_at: &str) -> String {
    json!([{"iid": 5, "title": "Add foo", "state": "opened", "updated_at": updated_at, "source_branch": "ABC-1/foo",
        "web_url": format!("{URL}/5"), "author": {"username": "bob"}}])
    .to_string()
}

fn fields(out: &str, keys: &[&str]) -> String {
    let event: Value = serde_json::from_str(out.lines().next().unwrap_or("null")).unwrap();
    keys.iter()
        .map(|key| support::raw(&event[key]))
        .collect::<Vec<_>>()
        .join(" ")
}

fn follow_lines(w: &Watchd) -> Vec<Value> {
    let text = std::fs::read_to_string(w.env.dir.join("follow.out")).unwrap_or_default();
    text.lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

/// The branch and the stage of the worktree, and the `live` value of its watch, in the last sidebar
/// line.
fn worktree_in_sidebar(w: &Watchd, worktree: &Path) -> String {
    let lines = follow_lines(w);
    let Some(sidebar) = lines.iter().rfind(|line| line["type"] == "sidebar") else {
        return String::new();
    };
    let path = worktree.to_str().unwrap();
    let state = &sidebar["worktrees"][path];
    let live = sidebar["subs"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|sub| sub["repo"] == path)
        .map_or(Value::Null, |sub| sub["live"].clone());
    format!("{} {} {live}", state["branch"], state["stage"])
}

fn hub_todo() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::with_gitlab_engine();
        let mut c = Checks::default();
        w.env.write_engine_state("app", r#"{"version": 4, "todos": []}"#);
        w.env.fixture("todos", &json!([{"id": 11, "action_name": "review_requested", "author": {"username": "anna"},
            "target": {"iid": 5, "title": "Add foo", "source_branch": "ABC-1/foo"},
            "target_url": format!("{URL}/5")}]).to_string());
        let run = w.watch_wait(&[]);
        c.check("e2e: real engine and fake glab give a todo event",
            format!(r#"0 {{"kind":"todo","iid":5,"title":"Add foo","url":"{URL}/5","actor":"anna","detail":"review_requested","branch":"ABC-1/foo","item":"todo:11"}}"#),
            format!("{} {}", run.code, norow(&run.out)));
        c
    })
}

fn review_and_hub() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::with_gitlab_engine();
        let mut c = Checks::default();
        let review_key = format!("{}-review-5", w.author_key());
        gql(&w, 5, |_| {});
        w.env.fixture(
            "events",
            r#"[{"project_id": 7, "note": {"id": 300, "noteable_type": "MergeRequest", "noteable_iid": 5}}]"#,
        );
        w.env.fixture("commented", &commented("t1"));
        // Two sessions, so that the review client gets no hub event.
        let other = "session-hub";
        let owner = session();
        w.watch(&["--review", "--mr", "5"]);
        w.run(w.as_session(w.watch_command(&[]), other, owner.id()));
        let review = w.start(w.wait_command());
        let hub = w.start(w.as_session(w.wait_command(), other, owner.id()));
        wait_for(10, || w.rounds_of("app") >= 1 && w.rounds_of(&review_key) >= 1);
        w.env.fixture("commented", &commented("t2"));
        w.env.fixture("notes_5", &json!([anna_note(301)]).to_string());
        w.env.fixture(
            "discussions_5",
            &json!([{"id": "d301", "individual_note": false, "notes": [anna_note(301)]}]).to_string(),
        );
        let hub_rounds = w.rounds_of("app");
        let review = review.wait(10).unwrap();
        c.check(
            "e2e review: real engine gives a comment to the review client",
            "0 comment anna",
            format!("{} {}", review.code, fields(&review.out, &["kind", "actor"])),
        );
        wait_for(5, || w.rounds_of("app") > hub_rounds);
        c.check(
            "e2e review: no note for the MR in the hub inbox",
            "running ",
            format!(
                "{} {}",
                if hub.running() { "running" } else { "stopped" },
                w.inbox_of("app")
            ),
        );
        let mut unsubscribe = w.command();
        unsubscribe.args([
            "unsubscribe",
            "--session",
            other,
            "--repo",
            w.env.repo.to_str().unwrap(),
        ]);
        w.run(unsubscribe);
        hub.code();
        end(owner);
        c
    })
}

fn shared_fetch() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::with_gitlab_engine();
        let mut c = Checks::default();
        gql(&w, 5, |_| {});
        w.env.fixture(
            "discussions_5",
            &json!([{"id": "d301", "individual_note": false, "notes": [anna_note(301)]}]).to_string(),
        );
        let git = |args: &[&str]| {
            let status = Command::new("git")
                .arg("-C")
                .arg(&w.env.repo)
                .args(["-c", "user.name=t", "-c", "user.email=t@t"])
                .args(args)
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .env("GIT_CONFIG_GLOBAL", w.env.dir.join("gitconfig"))
                .status()
                .unwrap();
            assert!(status.success());
        };
        git(&["commit", "-q", "--allow-empty", "-m", "init"]);
        let app2 = w.env.dir.join("app2");
        git(&["worktree", "add", "-q", app2.to_str().unwrap()]);
        let first = format!("{}-review-5", w.author_key());
        let mut hasher = Command::new("shasum")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        std::io::Write::write_all(hasher.stdin.as_mut().unwrap(), app2.to_str().unwrap().as_bytes()).unwrap();
        let second = format!(
            "app-{}-review-5",
            &String::from_utf8_lossy(&hasher.wait_with_output().unwrap().stdout)[..12]
        );
        w.env.clear_calls();
        w.watch(&["--interval", "600", "--review", "--mr", "5"]);
        wait_for(10, || w.rounds_of(&first) >= 1);
        let mut command = w.watch_command(&["--interval", "600", "--review", "--mr", "5"]);
        command.current_dir(&app2);
        w.run(command);
        wait_for(10, || w.rounds_of(&second) >= 1 && w.rounds_of(&first) >= 2);
        let fetches = w.env.calls().lines().filter(|line| line.ends_with(" iid=5")).count();
        c.check(
            "review and bump on the same MR: one fetch in each round",
            "2 2",
            format!("{} {fetches}", w.rounds_of(&first)),
        );
        w.unsubscribe(&["--repo", w.env.repo.to_str().unwrap(), "--review", "--mr", "5"]);
        w.unsubscribe(&["--repo", app2.to_str().unwrap(), "--review", "--mr", "5"]);
        c
    })
}

fn author_pipeline() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::with_gitlab_engine();
        let mut c = Checks::default();
        gql(&w, 5, |_| {});
        w.watch(&["--mr", "5"]);
        let author = w.start(w.wait_command());
        wait_for(10, || w.rounds_of(&w.author_key()) >= 1);
        gql(&w, 5, |mr| {
            mr["headPipeline"] = json!({"id": "gid://gitlab/Ci::Pipeline/50", "status": "FAILED"})
        });
        let author = author.wait(10).unwrap();
        c.check(
            "e2e author: real engine gives a pipeline event",
            "0 pipeline 5 pipeline 50 failed",
            format!("{} {}", author.code, fields(&author.out, &["kind", "iid", "detail"])),
        );
        c
    })
}

#[test]
fn e2e_real_engine_and_fake_glab_give_a_todo_event() {
    hub_todo().assert("e2e: real engine and fake glab give a todo event");
}

#[test]
fn e2e_review_real_engine_gives_a_comment_to_the_review_client() {
    review_and_hub().assert("e2e review: real engine gives a comment to the review client");
}

#[test]
fn e2e_review_no_note_for_the_mr_in_the_hub_inbox() {
    review_and_hub().assert("e2e review: no note for the MR in the hub inbox");
}

#[test]
fn review_and_bump_on_the_same_mr_one_fetch_in_each_round() {
    shared_fetch().assert("review and bump on the same MR: one fetch in each round");
}

#[test]
fn e2e_author_real_engine_gives_a_pipeline_event() {
    author_pipeline().assert("e2e author: real engine gives a pipeline event");
}

#[test]
fn e2e_worktree_watch_with_the_real_engine_shows_in_follow() {
    let mut w = Watchd::with_gitlab_engine();
    w.env.set_env("WATCHD_GRACE_SECONDS", "2");
    let wt = w.env.dir.join("wt");
    w.env.commit(&w.env.repo, "one");
    w.env.git(
        &w.env.repo,
        &["worktree", "add", "-q", "-b", "ABC-1/foo", wt.to_str().unwrap()],
    );
    gql(&w, 5, |_| {});
    let follow = w.follower(&wt);
    let owner = session();
    let key = format!("app-{}", support::hash12(&wt));

    let mut watch = w.watch_command(&["--mr", "5"]);
    watch.current_dir(&wt);
    let watched = w.run(watch);
    let waiter = w.start(w.as_session(w.wait_command(), &w.session_id(), owner.id()));
    wait_for(10, || w.rounds_of(&key) >= 1 && w.waiting(&w.session_id()));
    wait_for(5, || worktree_in_sidebar(&w, &wt).ends_with(" true"));
    let live = worktree_in_sidebar(&w, &wt);
    gql(&w, 5, |mr| {
        mr["headPipeline"] = json!({"id": "gid://gitlab/Ci::Pipeline/50", "status": "FAILED"})
    });
    let run = waiter.wait(10).expect("the waiter gets the pipeline event");
    end(owner);
    wait_for(10, || worktree_in_sidebar(&w, &wt).contains(r#""stopped""#));
    end(follow);

    assert_eq!(watched.code, 0, "{}", watched.err);
    assert_eq!(live, r#""ABC-1/foo" null true"#, "{}", w.log());
    assert_eq!(
        (run.code, fields(&run.out, &["kind", "iid", "detail"])),
        (0, "pipeline 5 pipeline 50 failed".to_string()),
        "{}",
        run.err
    );
    let event = follow_lines(&w)
        .into_iter()
        .find(|line| line["type"] == "event" && line["event"]["kind"] == "pipeline")
        .unwrap_or(Value::Null);
    assert_eq!(
        (event["event"]["iid"].clone(), event["id"].is_u64()),
        (json!(5), true),
        "{event}"
    );
    assert_eq!(
        worktree_in_sidebar(&w, &wt),
        r#""ABC-1/foo" "stopped" null"#,
        "{}",
        w.log()
    );
}
