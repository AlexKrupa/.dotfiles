mod support;

use std::process::Command;
use std::sync::OnceLock;

use serde_json::{Value, json};
use support::daemon::{Watchd, norow, wait_for};
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
    keys.iter().map(|key| support::raw(&event[key])).collect::<Vec<_>>().join(" ")
}

fn hub_todo() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::with_gitlab_engine();
        let mut c = Checks::default();
        w.env.write_engine_state("app", r#"{"todos": []}"#);
        w.env.fixture("todos", &json!([{"id": 11, "action_name": "review_requested", "author": {"username": "anna"},
            "target": {"iid": 5, "title": "Add foo", "source_branch": "ABC-1/foo"},
            "target_url": format!("{URL}/5")}]).to_string());
        let run = w.watch(&[]);
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
        let review_key = format!("{}-review-5", w.stack_key());
        gql(&w, 5, |_| {});
        w.env.fixture("events", r#"[{"project_id": 7, "note": {"id": 300, "noteable_type": "MergeRequest", "noteable_iid": 5}}]"#);
        w.env.fixture("commented", &commented("t1"));
        let review = w.start(w.watch_command(&["--review", "--mr", "5"]));
        let hub = w.start(w.watch_command(&[]));
        wait_for(10, || w.rounds_of("app") >= 1 && w.rounds_of(&review_key) >= 1);
        w.env.fixture("commented", &commented("t2"));
        w.env.fixture("notes_5", &json!([anna_note(301)]).to_string());
        w.env.fixture("discussions_5", &json!([{"id": "d301", "individual_note": false, "notes": [anna_note(301)]}]).to_string());
        let hub_rounds = w.rounds_of("app");
        let review = review.wait(10).unwrap();
        c.check("e2e review: real engine gives a comment to the review client", "0 comment anna",
            format!("{} {}", review.code, fields(&review.out, &["kind", "actor"])));
        wait_for(5, || w.rounds_of("app") > hub_rounds);
        c.check("e2e review: no note for the MR in the hub inbox", "running ",
            format!("{} {}", if hub.running() { "running" } else { "stopped" }, w.inbox_of("app")));
        w.client(&["unsubscribe", "--repo", w.env.repo.to_str().unwrap()]);
        hub.code();
        c
    })
}

fn shared_fetch() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::with_gitlab_engine();
        let mut c = Checks::default();
        gql(&w, 5, |_| {});
        w.env.fixture("discussions_5", &json!([{"id": "d301", "individual_note": false, "notes": [anna_note(301)]}]).to_string());
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
        let first = format!("{}-review-5", w.stack_key());
        let mut hasher = Command::new("shasum").stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).spawn().unwrap();
        std::io::Write::write_all(hasher.stdin.as_mut().unwrap(), app2.to_str().unwrap().as_bytes()).unwrap();
        let second = format!("app-{}-review-5", &String::from_utf8_lossy(&hasher.wait_with_output().unwrap().stdout)[..12]);
        w.env.clear_calls();
        let review = w.start(w.watch_command(&["--interval", "600", "--review", "--mr", "5"]));
        wait_for(10, || w.rounds_of(&first) >= 1);
        let mut command = w.watch_command(&["--interval", "600", "--review", "--mr", "5"]);
        command.current_dir(&app2);
        let bump = w.start(command);
        wait_for(10, || w.rounds_of(&second) >= 1 && w.rounds_of(&first) >= 2);
        let fetches = w.env.calls().lines().filter(|line| line.ends_with(" iid=5")).count();
        c.check("review and bump on the same MR: one fetch in each round", "2 2", format!("{} {fetches}", w.rounds_of(&first)));
        w.client(&["unsubscribe", "--repo", w.env.repo.to_str().unwrap(), "--review", "--mr", "5"]);
        w.client(&["unsubscribe", "--repo", app2.to_str().unwrap(), "--review", "--mr", "5"]);
        review.code();
        bump.wait(20);
        c
    })
}

fn stack_pipeline() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::with_gitlab_engine();
        let mut c = Checks::default();
        gql(&w, 5, |_| {});
        let stack = w.start(w.watch_command(&["--mr", "5"]));
        wait_for(10, || w.rounds_of(&w.stack_key()) >= 1);
        gql(&w, 5, |mr| mr["headPipeline"] = json!({"id": "gid://gitlab/Ci::Pipeline/50", "status": "FAILED"}));
        let stack = stack.wait(10).unwrap();
        c.check("e2e stack: real engine gives a pipeline event", "0 pipeline 5 pipeline 50 failed",
            format!("{} {}", stack.code, fields(&stack.out, &["kind", "iid", "detail"])));
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
fn e2e_stack_real_engine_gives_a_pipeline_event() {
    stack_pipeline().assert("e2e stack: real engine gives a pipeline event");
}
