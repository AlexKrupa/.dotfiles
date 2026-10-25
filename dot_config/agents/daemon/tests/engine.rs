//! The `engine` subcommand against a fake `glab`. Each scenario runs once, and each of its checks
//! is one test.

mod support;

use std::fmt;
use std::sync::OnceLock;

use serde_json::{Value, json};
use support::{Checks, PIPELINES, TestEnv, URL, each, field, raw, read_json, yes_no};

/// `$url` and `$pipelines` in an expected text.
fn u(text: &str) -> String {
    text.replace("$url", URL).replace("$pipelines", PIPELINES)
}

fn mr(iid: u64, title: &str, state: &str, updated_at: &str, author: &str, branch: &str) -> Value {
    json!({"iid": iid, "title": title, "state": state, "updated_at": updated_at, "source_branch": branch,
        "web_url": format!("{URL}/{iid}"), "author": {"username": author}})
}

/// The GraphQL response of MR `iid`, after `change` on the default MR.
fn gql(env: &TestEnv, iid: u64, change: impl FnOnce(&mut Value)) {
    let mut mr = json!({"iid": iid.to_string(), "title": "Add foo", "webUrl": format!("{URL}/{iid}"),
        "sourceBranch": "ABC-1/foo", "state": "opened", "draft": false, "author": {"username": "me"},
        "mergeUser": null, "headPipeline": null, "approvedBy": {"nodes": []},
        "detailedMergeStatus": "NOT_APPROVED", "conflicts": false, "mergeable": false});
    change(&mut mr);
    let response = json!({"data": {"currentUser": {"username": "me"}, "project": {"mergeRequest": mr}}});
    env.fixture(&format!("gql_{iid}"), &response.to_string());
}

fn plain(_: &mut Value) {}

fn pipeline(id: u64, status: &str) -> impl FnOnce(&mut Value) {
    move |mr| mr["headPipeline"] = json!({"id": format!("gid://gitlab/Ci::Pipeline/{id}"), "status": status})
}

fn discussions(env: &TestEnv, iid: u64, threads: &[Value]) {
    env.fixture(&format!("discussions_{iid}"), &Value::from(threads.to_vec()).to_string());
}

fn pos() -> Value {
    json!({"new_path": "app/Foo.kt", "new_line": 42, "old_path": "app/Foo.kt", "old_line": null})
}

fn note(id: u64, author: &str, body: &str, position: Option<Value>) -> Value {
    json!({"id": id, "body": body, "system": false, "author": {"username": author},
        "position": position.unwrap_or(Value::Null), "resolvable": true, "resolved": false, "resolved_by": null})
}

/// A thread of `notes`. `resolver` is empty for an open thread.
fn thread(resolver: &str, notes: Vec<Value>) -> Value {
    let id = format!("d{}", notes[0]["id"]);
    let notes: Vec<Value> = notes
        .into_iter()
        .map(|mut note| {
            note["resolved"] = json!(!resolver.is_empty());
            note["resolved_by"] = if resolver.is_empty() { Value::Null } else { json!({"username": resolver}) };
            note
        })
        .collect();
    json!({"id": id, "individual_note": false, "notes": notes})
}

/// A system note in a discussion of its own.
fn system_note(id: u64, author: &str, body: &str) -> Value {
    json!({"id": format!("s{id}"), "individual_note": true, "notes": [{"id": id, "body": body, "system": true,
        "author": {"username": author}, "resolvable": false, "resolved": false, "resolved_by": null}]})
}

fn refs(env: &TestEnv, base: &str, head: &str) {
    env.fixture("mr_5", &json!({"diff_refs": {"base_sha": base, "head_sha": head}}).to_string());
}

fn todo_9(id: u64, action: &str) -> Value {
    json!({"id": id, "action_name": action, "author": {"username": "anna"},
        "target": {"iid": 9, "title": "Fix bar", "source_branch": "ABC-2/bar", "author": {"username": "bob"}},
        "target_url": format!("{URL}/9")})
}

fn hub_note(id: u64, author: &str, resolved: bool) -> Value {
    json!({"id": id, "system": false, "body": "Why?", "author": {"username": author}, "resolvable": true,
        "resolved": resolved})
}

fn failed_pipeline(id: u64, status: &str) -> String {
    json!([{"id": id, "status": status, "web_url": format!("{PIPELINES}/{id}")}]).to_string()
}

/// An expected event line of a stack or review watch, with its fields in the order of the engine.
struct Line(Vec<(&'static str, Value)>);

impl Line {
    fn sev(kind: &str, iid: u64, actor: &str, detail: &str) -> Line {
        Line(vec![
            ("kind", json!(kind)),
            ("iid", json!(iid)),
            ("title", json!("Add foo")),
            ("url", json!(format!("{URL}/{iid}"))),
            ("actor", json!(actor)),
            ("detail", json!(detail)),
            ("branch", json!("ABC-1/foo")),
        ])
    }

    /// The URL of the note `id` of MR 5.
    fn note(self, id: u64) -> Line {
        self.set("url", json!(format!("{URL}/5#note_{id}")))
    }

    fn at(self, path: &str, line: u64) -> Line {
        self.add("path", json!(path)).add("line", json!(line))
    }

    fn item(self, item: &str) -> Line {
        self.add("item", json!(item))
    }

    fn add(mut self, key: &'static str, value: Value) -> Line {
        self.0.push((key, value));
        self
    }

    fn set(mut self, key: &'static str, value: Value) -> Line {
        self.0.iter_mut().find(|(field, _)| *field == key).expect("a field of the line").1 = value;
        self
    }
}

impl fmt::Display for Line {
    fn fmt(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        let fields: Vec<String> = self.0.iter().map(|(key, value)| format!("{}:{value}", json!(key))).collect();
        write!(formatter, "{{{}}}", fields.join(","))
    }
}

fn lines(lines: &[Line]) -> String {
    lines.iter().map(Line::to_string).collect::<Vec<_>>().join("\n")
}

fn pushed(head: &str, old_base: &str, old_head: &str, new_base: &str) -> Line {
    Line::sev("pushed", 5, "", &format!("pushed {head}"))
        .add("old_base", json!(old_base))
        .add("old_head", json!(old_head))
        .add("new_base", json!(new_base))
        .add("new_head", json!(head))
}

const EMPTY_HUB: &str = r#"{"todos": []}"#;

fn stack_key(env: &TestEnv) -> String {
    format!("app-{}", env.worktree_hash())
}

fn review_key(env: &TestEnv) -> String {
    format!("app-{}-review-5", env.worktree_hash())
}

fn hub_basics() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let mut env = TestEnv::new();
        let mut c = Checks::default();
        let state = env.engine_state("app");

        let run = env.run(&[]);
        c.check("first check: exit 0", 0, run.code);
        c.check("first check: no events", "", run.out);
        c.check("first check: state saved", "[]", field(&state, "todos"));

        env.fixture("todos", &json!([{"id": 11, "action_name": "review_requested", "author": {"username": "anna"},
            "target": {"iid": 5, "title": "Add foo", "source_branch": "ABC-1/foo"},
            "target_url": format!("{URL}/5")}]).to_string());
        c.check("new to-do item",
            u(r#"{"kind":"todo","iid":5,"title":"Add foo","url":"$url/5","actor":"anna","detail":"review_requested","branch":"ABC-1/foo","item":"todo:11"}"#),
            env.run(&[]).out);
        c.check("same to-do item: no events", "", env.run(&[]).out);
        env.fixture("todos", &json!([{"id": 12, "action_name": "assigned", "author": {"username": "me"},
            "target": {"iid": 6, "title": "Add baz", "source_branch": "ABC-3/baz", "author": {"username": "me"}},
            "target_url": format!("{URL}/6")}]).to_string());
        c.check("assigned to own MR: no events", "", env.run(&[]).out);

        env.set_env("MOCK_FAIL", "todos*");
        env.set_env("MOCK_FAIL_MSG", "glab: 403 Forbidden (HTTP 403)");
        let run = env.run(&[]);
        c.check("HTTP 403: exit 5", 5, run.code);
        c.check("HTTP 403: message",
            "watch-gitlab: HTTP 403 on todos?project_id=7&type=MergeRequest&state=pending&per_page=100. The token needs the Read permission for Todo (user boundary).",
            run.err);
        env.set_env("MOCK_FAIL_MSG", "dial tcp: i/o timeout");
        c.check("network error: exit 4", 4, env.run(&[]).code);
        env.set_env("MOCK_FAIL_MSG", "something odd");
        c.check("other error: exit 1", 1, env.run(&[]).code);
        env.set_env("MOCK_FAIL_MSG", "HTTP 404 Not Found");
        c.check("other error: message",
            "watch-gitlab: todos?project_id=7&type=MergeRequest&state=pending&per_page=100: HTTP 404 Not Found",
            env.run(&[]).err);
        env.remove_env("MOCK_FAIL");
        env.remove_env("MOCK_FAIL_MSG");

        env.set_env("MOCK_NOAUTH", "1");
        let run = env.run(&[]);
        c.check("glab not authenticated: exit 5", 5, run.code);
        c.check("glab not authenticated: message", "watch-gitlab: glab is not authenticated, run: glab auth login", run.err);
        env.remove_env("MOCK_NOAUTH");

        let app2 = env.dir.join("app2");
        env.git_repo(&app2, "git@gitlab.example.com:group/sub/app.git");
        let run = env.run_in(&app2, &[]);
        c.check("scp-style SSH remote: same project", "0 ", format!("{} {}{}", run.code, run.out, run.err));
        c
    })
}

fn hub_notes() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        env.write_engine_state("app", EMPTY_HUB);
        env.fixture("events", &json!([
            {"project_id": 7, "note": {"noteable_type": "MergeRequest", "noteable_iid": 9}},
            {"project_id": 8, "note": {"noteable_type": "MergeRequest", "noteable_iid": 4}},
            {"project_id": 7, "note": {"noteable_type": "Issue", "noteable_iid": 3}}]).to_string());
        env.fixture("commented", &json!([mr(9, "Fix bar", "merged", "t1", "bob", "ABC-2/bar")]).to_string());
        env.fixture("notes_9", &json!([{"id": 100, "system": false, "body": "old", "author": {"username": "bob"}}]).to_string());
        c.check("state with no mrs: no events for old notes", "", env.run(&[]).out);
        let commented = env.calls_with("api projects/7/merge_requests?state");
        c.check("commented MRs: only MRs of this project",
            "api projects/7/merge_requests?state=all&iids[]=9&per_page=100",
            commented.lines().last().unwrap_or_default());

        env.fixture("commented", &json!([mr(9, "Fix bar", "merged", "t2", "bob", "ABC-2/bar")]).to_string());
        env.fixture("notes_9", &json!([
            {"id": 102, "system": true, "body": "added 1 commit", "author": {"username": "anna"}},
            {"id": 101, "system": false, "body": "Please\nrename this", "author": {"username": "anna"}},
            {"id": 100, "system": false, "body": "old", "author": {"username": "bob"}}]).to_string());
        c.check("new note from a different user",
            u(r#"{"kind":"note","iid":9,"title":"Fix bar","url":"$url/9#note_101","actor":"anna","detail":"Please rename this","branch":"ABC-2/bar","item":"note:101"}"#),
            env.run(&[]).out);

        env.fixture("commented", &json!([mr(9, "Fix bar", "merged", "t3", "bob", "ABC-2/bar")]).to_string());
        env.fixture("notes_9", &json!([{"id": 104, "system": false, "body": "x".repeat(300),
            "author": {"username": "anna"}}]).to_string());
        let out = env.run(&[]).out;
        c.check("long note: one line", 1, out.lines().count());
        c.check("long note: detail has 100 characters", 100,
            serde_json::from_str::<Value>(&out).unwrap()["detail"].as_str().unwrap().chars().count());

        env.clear_calls();
        env.run(&[]);
        c.check("same updated_at: no notes call", "",
            env.calls().lines().filter(|line| line.contains("/notes?")).collect::<Vec<_>>().join("\n"));

        env.fixture("events", &json!([
            {"project_id": 7, "note": {"noteable_type": "MergeRequest", "noteable_iid": 9}},
            {"project_id": 7, "note": {"noteable_type": "MergeRequest", "noteable_iid": 5}}]).to_string());
        env.fixture("commented", &json!([mr(9, "Fix bar", "merged", "t3", "bob", "ABC-2/bar"),
            mr(5, "Add foo", "opened", "t1", "me", "ABC-1/foo")]).to_string());
        env.run(&[]);
        env.fixture("commented", &json!([mr(9, "Fix bar", "merged", "t3", "bob", "ABC-2/bar"),
            mr(5, "Add foo", "opened", "t2", "me", "ABC-1/foo")]).to_string());
        env.fixture("notes_5", &json!([{"id": 105, "system": false, "body": "Why?", "author": {"username": "anna"}}]).to_string());
        let run = env.run(&[]);
        c.check("note on an own MR: no events", "", run.out);
        c.check("own MRs: no own MRs call", "",
            run.err.lines().filter(|line| line.contains("own MRs call")).collect::<Vec<_>>().join("\n"));

        env.fixture("todos", &json!([{"id": 13, "action_name": "mentioned", "author": {"username": "anna"},
            "target": {"iid": 5, "title": "Add foo", "source_branch": "ABC-1/foo", "author": {"username": "me"}},
            "target_url": format!("{URL}/5")}]).to_string());
        c.check("to-do item on an own MR: no events", "", env.run(&[]).out);
        c
    })
}

fn hub_event_pages() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        env.write_engine_state("app", EMPTY_HUB);
        let events: Vec<Value> = (1..=100)
            .map(|iid| json!({"project_id": 7, "note": {"noteable_type": "MergeRequest", "noteable_iid": iid}}))
            .collect();
        env.fixture("events", &Value::from(events).to_string());
        env.fixture("events_p1", r#"[{"project_id": 7, "note": {"noteable_type": "MergeRequest", "noteable_iid": 101}}]"#);
        env.clear_calls();
        env.run(&[]);
        let mut calls: Vec<String> =
            env.calls_with("api projects/7/merge_requests?state=all").lines().map(str::to_string).collect();
        calls.sort();
        let last = calls.last().cloned().unwrap_or_default();
        let last = last.rsplit_once("state=all&").map_or(last.clone(), |(_, rest)| rest.to_string());
        c.check("commented MRs: all event pages, one call for each 100 MRs", "2 iids[]=101&per_page=100",
            format!("{} {last}", calls.len()));
        c
    })
}

fn hub_reactions() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        env.write_engine_state("app", EMPTY_HUB);
        env.fixture("events", r#"[{"project_id": 7, "note": {"id": 200, "noteable_type": "MergeRequest", "noteable_iid": 9}}]"#);
        env.fixture("commented", &json!([mr(9, "Fix bar", "opened", "t1", "bob", "ABC-2/bar")]).to_string());
        env.fixture("award_note_201", r#"[{"name": "eyes", "user": {"username": "anna"}}]"#);
        env.run(&[]);
        env.fixture("award_note_200", r#"[{"name": "tada", "user": {"username": "anna"}},
            {"name": "eyes", "user": {"username": "me"}}]"#);
        env.clear_calls();
        let out = env.run(&[]).out;
        c.check("hub: reactions from REST, not GraphQL", "", env.calls_with("api graphql"));
        c.check("hub: reaction on an own comment, not own reactions or reactions on other comments",
            u(r#"{"kind":"reaction","iid":9,"title":"Fix bar","url":"$url/9#note_200","actor":"anna","detail":":tada: on your comment","branch":"ABC-2/bar"}"#),
            out);
        c.check("hub: same reaction: no events", "", env.run(&[]).out);
        c
    })
}

fn default_pipeline() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        let state = env.engine_state("app");
        env.write_engine_state("app", EMPTY_HUB);
        env.fixture("pipelines", &failed_pipeline(70, "failed"));
        env.clear_calls();
        let out = env.run(&[]).out;
        c.check("default branch pipeline: ref and scope", "api projects/7/pipelines?ref=dev%2Fx&scope=finished&per_page=1",
            env.calls_with("api projects/7/pipelines"));
        c.check("state with no default pipeline: no events", "", out);
        env.fixture("pipelines", &failed_pipeline(71, "failed"));
        c.check("default branch pipeline failed",
            u(r#"{"kind":"default-failed","iid":null,"title":null,"url":"$pipelines/71","actor":"","detail":"pipeline 71 failed","branch":"dev/x","previous":"failed","item":"main-failed:dev/x","jobs":[]}"#),
            env.run(&[]).out);
        c.check("same default branch pipeline: no events", "", env.run(&[]).out);
        env.fixture("pipelines", &failed_pipeline(72, "success"));
        c.check("default branch pipeline passed: no events", "", env.run(&[]).out);
        env.fixture("pipelines", &failed_pipeline(69, "failed"));
        c.check("older pipeline during a retry: no events", "", env.run(&[]).out);
        c.check("older pipeline during a retry: state keeps 72", r#"{"id":72,"status":"success"}"#,
            field(&state, "default_pipeline"));
        env.fixture("pipelines", &failed_pipeline(72, "failed"));
        c.check("retried pipeline failed again: no events", "", env.run(&[]).out);
        env.fixture("pipelines", &failed_pipeline(73, "failed"));
        c.check("failure after a failure: previous failed", "failed", each(&env.run(&[]).out, "previous"));
        env.fixture("pipelines", &failed_pipeline(74, "success"));
        env.run(&[]);
        env.fixture("pipelines", &failed_pipeline(75, "failed"));
        c.check("failure after a pass: previous success", "success", each(&env.run(&[]).out, "previous"));
        env.write_engine_state("app", r#"{"todos": [], "mrs": {}, "default_pipeline": null}"#);
        c.check("saved null pipeline: event with previous null", "null", each(&env.run(&[]).out, "previous"));
        env.fixture("pipelines", &failed_pipeline(88123, "failed"));
        env.fixture("jobs_88123", r#"[{"name": "unit-tests"}]"#);
        c.check("default-failed: jobs", r#"["unit-tests"]"#, each(&env.run(&[]).out, "jobs"));
        c
    })
}

fn opened_mrs() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        env.write_engine_state("app", EMPTY_HUB);
        let foo = mr(20, "Update dependency foo to v2", "opened", "t1", "renovate-bot", "renovate/foo-2.x");
        env.fixture("opened", &json!([foo]).to_string());
        env.clear_calls();
        let out = env.run(&[]).out;
        c.check("open MRs: newest first",
            "api projects/7/merge_requests?state=opened&order_by=created_at&sort=desc&per_page=100",
            env.calls_with("api projects/7/merge_requests?state=opened"));
        c.check("state with no open MRs: no events for open MRs", "", out);
        env.fixture("opened", &json!([mr(22, "Add qux", "opened", "t1", "me", "ABC-4/qux"),
            mr(21, "Update dependency bar to v3", "opened", "t1", "renovate-bot", "renovate/bar-3.x"), foo]).to_string());
        c.check("new MR of a different user, not own MRs",
            u(r#"{"kind":"opened","iid":21,"title":"Update dependency bar to v3","url":"$url/21","actor":"renovate-bot","detail":"opened","branch":"renovate/bar-3.x"}"#),
            env.run(&[]).out);
        c.check("same open MRs: no events", "", env.run(&[]).out);
        c
    })
}

fn skip_mr() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        env.write_engine_state("app", EMPTY_HUB);
        env.fixture("commented", &json!([mr(9, "Fix bar", "opened", "t1", "bob", "ABC-2/bar")]).to_string());
        env.fixture("events", r#"[{"project_id": 7, "note": {"noteable_type": "MergeRequest", "noteable_iid": 9}}]"#);
        env.run(&[]);
        env.fixture("todos", &json!([todo_9(21, "mentioned"), todo_9(22, "review_requested")]).to_string());
        env.fixture("commented", &json!([mr(9, "Fix bar", "opened", "t2", "bob", "ABC-2/bar")]).to_string());
        env.fixture("notes_9", r#"[{"id": 301, "system": false, "body": "Odd", "author": {"username": "anna"}}]"#);
        c.check("--skip-mr: only the review request and opened",
            u(r#"{"kind":"todo","iid":9,"title":"Fix bar","url":"$url/9","actor":"anna","detail":"review_requested","branch":"ABC-2/bar","item":"todo:22"}"#),
            env.run(&["--skip-mr", "9"]).out);
        c
    })
}

fn stack_basics() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let mut env = TestEnv::new();
        let mut c = Checks::default();
        let sstate = env.engine_state(&stack_key(&env));
        let iid_calls = |env: &TestEnv| env.calls().lines().filter(|line| line.ends_with(" iid=5")).count();

        gql(&env, 5, plain);
        env.clear_calls();
        let run = env.run(&["--mr", "5"]);
        c.check("stack: first check: exit 0", 0, run.code);
        c.check("stack: first check: no events", "", run.out);
        c.check("stack: own state file", "yes", yes_no(&sstate));
        let cache = env.dir.join("cache");
        std::fs::create_dir_all(&cache).unwrap();
        env.clear_calls();
        env.set_env("WATCH_MR_CACHE", cache.to_str().unwrap());
        env.run(&["--mr", "5"]);
        env.run(&["--fresh", "--mr", "5"]);
        c.check("MR cache: second fetch reads the cache", 1, iid_calls(&env));
        c.check("MR cache: file written", "yes", yes_no(&cache.join("group%2Fsub%2Fapp-5.json")));
        let other = env.dir.join("cache-other");
        std::fs::create_dir_all(&other).unwrap();
        std::fs::write(other.join("5.json"), r#"{"note": "MR 5 of a different project with the same repo directory name"}"#).unwrap();
        env.clear_calls();
        env.set_env("WATCH_MR_CACHE", other.to_str().unwrap());
        env.run(&["--fresh", "--mr", "5"]);
        c.check("MR cache: the MR of a different project is not read", 1, iid_calls(&env));
        env.remove_env("WATCH_MR_CACHE");

        gql(&env, 5, pipeline(50, "FAILED"));
        c.check("stack: pipeline failed",
            Line::sev("pipeline", 5, "", "pipeline 50 failed").item("pipeline:5").add("jobs", json!([])),
            env.run(&["--mr", "5"]).out);
        c.check("stack: same pipeline: no events", "", env.run(&["--mr", "5"]).out);
        gql(&env, 5, pipeline(51, "RUNNING"));
        c.check("stack: running pipeline: no events", "", env.run(&["--mr", "5"]).out);
        gql(&env, 5, pipeline(51, "SUCCESS"));
        c.check("stack: pipeline passed, iid with !", Line::sev("pipeline", 5, "", "pipeline 51 passed"),
            env.run(&["--mr", "!5"]).out);
        gql(&env, 5, pipeline(4567, "FAILED"));
        env.fixture("jobs_4567", r#"[{"name": "unit-tests"}, {"name": "ktlint"}, {"name": "ktlint"}]"#);
        c.check("pipeline failed: jobs", r#"["ktlint","unit-tests"]"#, each(&env.run(&["--mr", "5"]).out, "jobs"));
        gql(&env, 5, pipeline(4568, "SUCCESS"));
        c.check("pipeline passed: no jobs", "null", each(&env.run(&["--mr", "5"]).out, "jobs"));

        gql(&env, 5, |mr| mr["approvedBy"]["nodes"] = json!([{"username": "anna"}]));
        c.check("stack: approved", Line::sev("approved", 5, "anna", "approved"), env.run(&["--mr", "5"]).out);
        gql(&env, 5, plain);
        c.check("stack: unapproved", Line::sev("unapproved", 5, "anna", "approval removed"), env.run(&["--mr", "5"]).out);
        gql(&env, 5, |mr| mr["approvedBy"]["nodes"] = json!([{"username": "me"}]));
        c.check("stack: own approval: no events", "", env.run(&["--mr", "5"]).out);
        gql(&env, 5, plain);
        c.check("stack: own approval removed: no events", "", env.run(&["--mr", "5"]).out);

        gql(&env, 5, |mr| {
            mr["conflicts"] = json!(true);
            mr["detailedMergeStatus"] = json!("CONFLICT");
        });
        c.check("stack: conflict", Line::sev("conflict", 5, "", "merge conflict").item("conflict:5"),
            env.run(&["--mr", "5"]).out);
        gql(&env, 5, |mr| mr["detailedMergeStatus"] = json!("CHECKING"));
        c.check("stack: transient status: no events", "", env.run(&["--mr", "5"]).out);
        c.check("stack: transient status: old conflict value stays", "true",
            raw(&read_json(&sstate)["mrs"]["5"]["conflicts"]));
        gql(&env, 5, |mr| {
            mr["detailedMergeStatus"] = json!("MERGEABLE");
            mr["mergeable"] = json!(true);
        });
        discussions(&env, 5, &[thread("", vec![note(99, "anna", "Nit", None)])]);
        let out = env.run(&["--mr", "5"]).out;
        c.check("stack: mergeable with open threads", Line::sev("mergeable", 5, "", "now mergeable, 1 open thread(s)"),
            out.lines().filter(|line| line.contains(r#""mergeable""#)).collect::<Vec<_>>().join("\n"));
        c
    })
}

fn stack_comments() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        let why = || note(101, "anna", "Why\nnot X?", Some(pos()));
        gql(&env, 5, plain);
        discussions(&env, 5, &[thread("", vec![note(100, "anna", "old", None)])]);
        c.check("stack: old comments of a new MR: no events", "", env.run(&["--mr", "5"]).out);
        discussions(&env, 5, &[thread("", vec![note(100, "anna", "old", None), why()])]);
        c.check("stack: new comment and its thread",
            lines(&[
                Line::sev("comment", 5, "anna", "Why not X?").note(101).at("app/Foo.kt", 42).item("thread:d100"),
                Line::sev("unaddressed", 5, "anna", "Why not X?").note(101).item("thread:d100"),
            ]),
            env.run(&["--mr", "5"]).out);
        discussions(&env, 5, &[thread("", vec![note(100, "anna", "old", None), why(), note(102, "me", "Because Y.", None)])]);
        c.check("stack: own reply", Line::sev("own-comment", 5, "me", "Because Y.").note(102), env.run(&["--mr", "5"]).out);
        discussions(&env, 5, &[
            thread("bob", vec![note(103, "bob", "Done?", Some(pos()))]),
            thread("", vec![note(104, "bob", "Typo", Some(pos()))]),
            system_note(105, "anna", "added 1 commit"),
        ]);
        env.clear_calls();
        c.check("stack: resolved thread and system note: no unaddressed line for them",
            lines(&[
                Line::sev("comment", 5, "bob", "Done?").note(103).at("app/Foo.kt", 42),
                Line::sev("comment", 5, "bob", "Typo").note(104).at("app/Foo.kt", 42).item("thread:d104"),
                Line::sev("unaddressed", 5, "bob", "Typo").note(104).at("app/Foo.kt", 42).item("thread:d104"),
            ]),
            env.run(&["--mr", "5"]).out);
        let reacted: std::collections::BTreeSet<String> = env
            .calls()
            .split("notes/")
            .skip(1)
            .filter_map(|rest| rest.split_once("/award_emoji").map(|(id, _)| id.to_string()))
            .filter(|id| !id.is_empty() && id.bytes().all(|byte| byte.is_ascii_digit()))
            .collect();
        c.check("stack: one reaction call for each comment, none for a system note", "103 104",
            reacted.into_iter().collect::<Vec<_>>().join(" "));
        c
    })
}

fn stack_reactions() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        gql(&env, 5, plain);
        discussions(&env, 5, &[thread("", vec![note(110, "me", "See this", Some(pos()))])]);
        env.run(&["--mr", "5"]);
        env.fixture("award_mr_5", r#"[{"name": "thumbsup", "user": {"username": "bob"}},
            {"name": "eyes", "user": {"username": "me"}}]"#);
        env.fixture("award_note_110", r#"[{"name": "tada", "user": {"username": "anna"}}]"#);
        c.check("stack: reactions on the MR and on an own comment, not own reactions",
            lines(&[
                Line::sev("reaction", 5, "bob", ":thumbsup: on the MR"),
                Line::sev("reaction", 5, "anna", ":tada: on your comment").note(110).at("app/Foo.kt", 42),
            ]),
            env.run(&["--mr", "5"]).out);
        c.check("stack: same reactions: no events", "", env.run(&["--mr", "5"]).out);
        gql(&env, 5, |mr| {
            mr["state"] = json!("merged");
            mr["mergeUser"] = json!({"username": "anna"});
        });
        c.check("stack: merged", Line::sev("merged", 5, "anna", "merged"), env.run(&["--mr", "5"]).out);
        c
    })
}

/// A first check of MR 5, then a check after `change` of the MR and its discussions.
fn after_change(env: &TestEnv, change: impl FnOnce(&mut Value), threads: Option<&[Value]>) -> String {
    gql(env, 5, plain);
    env.run(&["--mr", "5"]);
    gql(env, 5, change);
    if let Some(threads) = threads {
        discussions(env, 5, threads);
    }
    env.run(&["--mr", "5"]).out
}

fn stack_ends() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let mut c = Checks::default();
        let closed = |mr: &mut Value| mr["state"] = json!("closed");
        let merged_by = |user: &'static str| move |mr: &mut Value| {
            mr["state"] = json!("merged");
            mr["mergeUser"] = json!({"username": user});
        };
        c.check("stack: closed", Line::sev("closed", 5, "anna", "closed"),
            after_change(&TestEnv::new(), closed, Some(&[system_note(120, "anna", "closed")])));
        c.check("stack: own close", Line::sev("closed", 5, "me", "closed").add("own", json!(true)),
            after_change(&TestEnv::new(), closed, Some(&[system_note(121, "me", "closed")])));
        c.check("stack: own merge", Line::sev("merged", 5, "me", "merged").add("own", json!(true)),
            after_change(&TestEnv::new(), merged_by("me"), None));
        c
    })
}

fn stack_draft() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        let draft = system_note(122, "anna", "marked this merge request as **draft**");
        c.check("stack: marked as draft", Line::sev("draft", 5, "anna", "marked as draft"),
            after_change(&env, |mr| mr["draft"] = json!(true), Some(&[draft.clone()])));
        gql(&env, 5, plain);
        discussions(&env, 5, &[draft, system_note(123, "me", "marked this merge request as **ready**")]);
        c.check("stack: own ready: no events", "", env.run(&["--mr", "5"]).out);
        env.run(&["--mr", "5"]);
        gql(&env, 5, |mr| mr["draft"] = json!(true));
        discussions(&env, 5, &[]);
        c.check("stack: draft with no system note", Line::sev("draft", 5, "", "marked as draft"), env.run(&["--mr", "5"]).out);
        c
    })
}

fn stack_title() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        gql(&env, 5, plain);
        env.fixture("mr_5", r#"{"description": "Old text", "labels": ["wip", "app"]}"#);
        env.run(&["--mr", "5"]);
        gql(&env, 5, |mr| mr["title"] = json!("Add foo and bar"));
        env.fixture("mr_5", r#"{"description": "New text", "labels": ["app", "bug"]}"#);
        discussions(&env, 5, &[
            system_note(130, "anna", "changed title from **Add foo** to **Add foo and bar**"),
            system_note(131, "anna", "changed the description"),
            system_note(132, "bob", "added ~7 label and removed ~8 label"),
        ]);
        let title = json!("Add foo and bar");
        c.check("stack: title, description, and labels changed",
            lines(&[
                Line::sev("title", 5, "anna", "Add foo and bar").set("title", title.clone()),
                Line::sev("description", 5, "anna", "description changed").set("title", title.clone()),
                Line::sev("labels", 5, "bob", "+bug, -wip").set("title", title),
            ]),
            env.run(&["--mr", "5"]).out);
        gql(&env, 5, plain);
        env.fixture("mr_5", r#"{"description": "Own text", "labels": []}"#);
        discussions(&env, 5, &[
            system_note(133, "me", "changed title from **Add foo and bar** to **Add foo**"),
            system_note(134, "me", "changed the description"),
            system_note(135, "me", "removed ~7 ~9 labels"),
        ]);
        c.check("stack: own title, description, and label changes: no events", "", env.run(&["--mr", "5"]).out);
        c
    })
}

fn stack_pages() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let mut c = Checks::default();

        let env = TestEnv::new();
        gql(&env, 5, plain);
        gql(&env, 6, plain);
        env.run(&["--mr", "5", "--mr", "6"]);
        gql(&env, 5, |mr| mr["approvedBy"]["nodes"] = json!([{"username": "anna"}]));
        gql(&env, 6, |mr| mr["approvedBy"]["nodes"] = json!([{"username": "bob"}]));
        c.check("stack: two MRs in the order of the options",
            lines(&[Line::sev("approved", 6, "bob", "approved"), Line::sev("approved", 5, "anna", "approved")]),
            env.run(&["--mr", "6", "--mr", "5"]).out);

        let env = TestEnv::new();
        gql(&env, 5, plain);
        discussions(&env, 5, &[thread("", vec![note(120, "anna", "old", None)])]);
        env.run(&["--mr", "5"]);
        env.fixture("discussions_5_p2", &json!([thread("", vec![note(121, "bob", "On page 2", None)])]).to_string());
        c.check("stack: comment on the second page of discussions",
            lines(&[
                Line::sev("comment", 5, "bob", "On page 2").note(121).item("thread:d121"),
                Line::sev("unaddressed", 5, "anna", "old").note(120).item("thread:d120"),
                Line::sev("unaddressed", 5, "bob", "On page 2").note(121).item("thread:d121"),
            ]),
            env.run(&["--mr", "5"]).out);
        c
    })
}

fn stack_errors() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let mut env = TestEnv::new();
        let mut c = Checks::default();
        gql(&env, 5, plain);
        env.fixture("mr_5", r#"{"user_notes_count": 2}"#);
        discussions(&env, 5, &[system_note(125, "anna", "added 1 commit")]);
        let run = env.run(&["--mr", "5"]);
        c.check("stack: comments that the token cannot read: exit 5", 5, run.code);
        c.check("stack: comments that the token cannot read: message",
            "watch-gitlab: MR !5 has 2 comment(s), but projects/group%2Fsub%2Fapp/merge_requests/5/discussions?per_page=100 gave none. The token needs the Read permission for Work Item (group or project boundary).",
            run.err);
        env.fixture("mr_5", "{}");
        env.set_env("MOCK_FAIL", "*/discussions*");
        env.set_env("MOCK_FAIL_MSG", "glab: 403 Forbidden (HTTP 403)");
        c.check("stack: HTTP 403 on discussions: message",
            "watch-gitlab: HTTP 403 on projects/group%2Fsub%2Fapp/merge_requests/5/discussions?per_page=100. The token needs the Read permission for Work Item (group or project boundary).",
            env.run(&["--mr", "5"]).err);
        env.remove_env("MOCK_FAIL");
        env.remove_env("MOCK_FAIL_MSG");

        let run = env.run(&["--mr", "7"]);
        c.check("stack: unknown MR: exit 5", 5, run.code);
        c.check("stack: unknown MR: message", "watch-gitlab: MR !7 not found in group/sub/app", run.err);
        env.fixture("gql_5", r#"{"errors": [{"message": "Field 'awardEmoji' does not exist"}]}"#);
        let run = env.run(&["--mr", "5"]);
        c.check("stack: GraphQL error: exit 5", 5, run.code);
        c.check("stack: GraphQL error: message", "watch-gitlab: graphql: Field 'awardEmoji' does not exist", run.err);
        c.check("stack: bad MR: message", "watch-gitlab: --mr needs an MR number", env.run(&["--mr", "x"]).err);
        c.check("review: no --mr: message", "watch-gitlab: --review needs exactly one --mr", env.run(&["--review"]).err);
        c.check("review: two --mr: message", "watch-gitlab: --review needs exactly one --mr",
            env.run(&["--review", "--mr", "5", "--mr", "6"]).err);
        c
    })
}

fn review_pushes() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        let review = ["--review", "--mr", "5"];
        gql(&env, 5, plain);
        c.check("review: first check: no events", "", env.run(&review).out);
        c.check("review: own state file", "yes", yes_no(&env.engine_state(&review_key(&env))));
        c.check("review: no stack state file", "no", yes_no(&env.engine_state(&stack_key(&env))));
        refs(&env, "b1", "h1");
        c.check("review: diffRefs after no diffRefs: no events", "", env.run(&review).out);
        refs(&env, "b1", "h2");
        c.check("review: pushed", pushed("h2", "b1", "h1", "b1"), env.run(&review).out);
        refs(&env, "b2", "h3");
        c.check("review: pushed after a rebase", pushed("h3", "b1", "h2", "b2"), env.run(&review).out);
        refs(&env, "b2", "h4");
        let run = env.run(&["--review", "--fresh", "--mr", "5"]);
        c.check("review: --fresh: old state not used, exit 0 and no events", "0 ", format!("{} {}", run.code, run.out));
        refs(&env, "b2", "h5");
        c.check("review: --fresh: new state saved", pushed("h5", "b2", "h4", "b2"), env.run(&review).out);
        c
    })
}

fn stack_push() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        gql(&env, 5, plain);
        refs(&env, "b1", "h1");
        env.run(&["--mr", "5"]);
        refs(&env, "b1", "h2");
        c.check("stack: push: no events", "", env.run(&["--mr", "5"]).out);
        c
    })
}

fn review_threads() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let mut c = Checks::default();
        let review = ["--review", "--mr", "5"];

        let env = TestEnv::new();
        gql(&env, 5, plain);
        let rename = || note(130, "me", "Rename this", Some(pos()));
        let typo = || note(131, "anna", "Typo", Some(pos()));
        discussions(&env, 5, &[thread("", vec![rename()]), thread("", vec![typo()])]);
        env.run(&review);
        discussions(&env, 5, &[thread("bob", vec![rename()]), thread("bob", vec![typo()])]);
        c.check("review: resolved, only threads that the user started",
            Line::sev("resolved", 5, "bob", "Rename this").note(130).at("app/Foo.kt", 42), env.run(&review).out);
        c.check("review: same resolved thread: no events", "", env.run(&review).out);

        let env = TestEnv::new();
        gql(&env, 5, plain);
        discussions(&env, 5, &[thread("", vec![note(135, "me", "Rename this", Some(pos()))])]);
        env.run(&review);
        discussions(&env, 5, &[thread("me", vec![note(135, "me", "Rename this", Some(pos()))])]);
        c.check("review: thread resolved by the user: no events", "", env.run(&review).out);

        let env = TestEnv::new();
        gql(&env, 5, plain);
        let why = || note(140, "me", "Why?", Some(pos()));
        let nit = || thread("", vec![note(141, "anna", "Nit", Some(pos()))]);
        discussions(&env, 5, &[thread("", vec![why()]), nit()]);
        env.run(&review);
        discussions(&env, 5, &[thread("", vec![why(), note(142, "bob", "Because.", None)]), nit()]);
        c.check("review: unaddressed only for threads with a note from the user",
            lines(&[
                Line::sev("comment", 5, "bob", "Because.").note(142).item("thread:d140"),
                Line::sev("unaddressed", 5, "bob", "Because.").note(142).at("app/Foo.kt", 42).item("thread:d140"),
            ]),
            env.run(&review).out);
        c
    })
}

/// The needs of the stack state after one check of `iids`.
fn stack_needs(change: impl FnOnce(&TestEnv), iids: &[&str]) -> String {
    let env = TestEnv::new();
    change(&env);
    let mut args = Vec::new();
    for iid in iids {
        args.extend(["--mr", iid]);
    }
    env.run(&args);
    field(&env.engine_state(&stack_key(&env)), "needs")
}

fn needs() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let mut c = Checks::default();
        c.check("stack needs: failed pipeline and an open thread", r#"["failed","reply"]"#,
            stack_needs(|env| {
                gql(env, 5, pipeline(60, "FAILED"));
                discussions(env, 5, &[thread("", vec![note(150, "anna", "Nit", None)])]);
            }, &["5"]));

        let env = TestEnv::new();
        let sstate = env.engine_state(&stack_key(&env));
        gql(&env, 5, |mr| {
            mr["detailedMergeStatus"] = json!("MERGEABLE");
            mr["mergeable"] = json!(true);
        });
        env.run(&["--mr", "5"]);
        c.check("stack needs: mergeable MR is ready", r#"["ready"]"#, field(&sstate, "needs"));
        gql(&env, 5, |mr| mr["detailedMergeStatus"] = json!("CHECKING"));
        env.run(&["--mr", "5"]);
        c.check("stack needs: a transient merge status keeps ready", r#"["ready"]"#, field(&sstate, "needs"));

        c.check("stack needs: need_rebase is a conflict", r#"["conflict"]"#,
            stack_needs(|env| gql(env, 5, |mr| mr["detailedMergeStatus"] = json!("NEED_REBASE")), &["5"]));
        c.check("stack needs: worst over two MRs", r#"["failed","draft"]"#,
            stack_needs(|env| {
                gql(env, 5, pipeline(61, "FAILED"));
                gql(env, 6, |mr| mr["draft"] = json!(true));
            }, &["5", "6"]));
        c.check("stack needs: a merged MR needs nothing", "[]",
            stack_needs(|env| gql(env, 5, |mr| {
                mr["state"] = json!("merged");
                mr["draft"] = json!(true);
            }), &["5"]));

        let env = TestEnv::new();
        let rstate = env.engine_state(&review_key(&env));
        let review = ["--review", "--mr", "5"];
        gql(&env, 5, plain);
        refs(&env, "b1", "h1");
        env.run(&review);
        refs(&env, "b1", "h2");
        env.run(&review);
        c.check("review needs: a push after the first check gives commits", r#"["commits"]"#, field(&rstate, "needs"));
        discussions(&env, 5, &[thread("", vec![note(160, "me", "Looks good now", None)])]);
        env.run(&review);
        c.check("review needs: a comment of the user after the push clears commits", "[]", field(&rstate, "needs"));
        refs(&env, "b1", "h3");
        env.run(&review);
        gql(&env, 5, |mr| mr["approvedBy"]["nodes"] = json!([{"username": "me"}]));
        env.run(&review);
        c.check("review needs: an approval of the user after the push clears commits", "[]", field(&rstate, "needs"));

        let env = TestEnv::new();
        env.fixture("todos", &json!([todo_9(31, "review_requested")]).to_string());
        env.fixture("pipelines", &failed_pipeline(80, "failed"));
        env.run(&[]);
        c.check("hub needs: pending to-do and failed default pipeline", r#"["todo","main-failed"]"#,
            field(&env.engine_state("app"), "needs"));

        c.check("stack needs: nothing", "[]", stack_needs(|env| gql(env, 5, plain), &["5"]));
        c
    })
}

fn present() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let mut c = Checks::default();

        let env = TestEnv::new();
        let state = env.engine_state("app");
        env.write_engine_state("app", EMPTY_HUB);
        env.fixture("todos", &json!([todo_9(41, "mentioned")]).to_string());
        c.check("todo: item key", "todo:41", each(&env.run(&[]).out, "item"));
        c.check("todo: present", r#"["todo:41"]"#, field(&state, "present"));
        env.fixture("todos", "[]");
        env.run(&[]);
        c.check("todo done: not present", "[]", field(&state, "present"));

        let env = TestEnv::new();
        let state = env.engine_state("app");
        env.write_engine_state("app", EMPTY_HUB);
        env.fixture("events", r#"[{"project_id": 7, "note": {"noteable_type": "MergeRequest", "noteable_iid": 9}}]"#);
        let notes = |updated_at: &str, notes: Value| {
            env.fixture("commented", &json!([mr(9, "Fix bar", "opened", updated_at, "bob", "ABC-2/bar")]).to_string());
            env.fixture("notes_9", &notes.to_string());
            env.run(&[]).out
        };
        notes("t1", json!([hub_note(500, "anna", false)]));
        let out = notes("t2", json!([hub_note(501, "anna", false), hub_note(500, "anna", false)]));
        c.check("note: item key", "note:501", each(&out, "item"));
        c.check("note: present", r#"["note:501"]"#, field(&state, "present"));
        notes("t3", json!([hub_note(502, "me", false), hub_note(501, "anna", false), hub_note(500, "anna", false)]));
        c.check("own reply: note not present", "[]", field(&state, "present"));
        notes("t4", json!([hub_note(503, "anna", false), hub_note(502, "me", false)]));
        notes("t5", json!([hub_note(503, "anna", true), hub_note(502, "me", false)]));
        c.check("resolved: note not present", "[]", field(&state, "present"));

        let env = TestEnv::new();
        let state = env.engine_state("app");
        env.write_engine_state("app", EMPTY_HUB);
        env.fixture("pipelines", &failed_pipeline(90, "failed"));
        env.run(&[]);
        env.fixture("pipelines", &failed_pipeline(91, "failed"));
        c.check("default-failed: item key", "main-failed:dev/x", each(&env.run(&[]).out, "item"));
        c.check("default-failed: present", r#"["main-failed:dev/x"]"#, field(&state, "present"));
        env.fixture("pipelines", &failed_pipeline(92, "success"));
        env.run(&[]);
        c.check("default passed: not present", "[]", field(&state, "present"));

        let env = TestEnv::new();
        let sstate = env.engine_state(&stack_key(&env));
        let old = || note(600, "anna", "old", None);
        let why = || note(601, "anna", "Why?", None);
        gql(&env, 5, plain);
        discussions(&env, 5, &[thread("", vec![old()])]);
        env.run(&["--mr", "5"]);
        discussions(&env, 5, &[thread("", vec![old(), why()])]);
        c.check("comment and unaddressed: one item key", "thread:d600 thread:d600",
            each(&env.run(&["--mr", "5"]).out, "item"));
        c.check("unaddressed thread: present", r#"["thread:d600"]"#, field(&sstate, "present"));
        discussions(&env, 5, &[thread("", vec![old(), why(), note(602, "me", "Because.", None)])]);
        env.run(&["--mr", "5"]);
        c.check("answered thread: not present", "[]", field(&sstate, "present"));

        let env = TestEnv::new();
        let sstate = env.engine_state(&stack_key(&env));
        gql(&env, 5, pipeline(62, "FAILED"));
        env.run(&["--mr", "5"]);
        c.check("pipeline failed: present", r#"["pipeline:5"]"#, field(&sstate, "present"));
        gql(&env, 5, |mr| {
            mr["conflicts"] = json!(true);
            mr["detailedMergeStatus"] = json!("CONFLICT");
        });
        env.run(&["--mr", "5"]);
        c.check("conflict: present", r#"["conflict:5"]"#, field(&sstate, "present"));
        c
    })
}

fn arguments() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let env = TestEnv::new();
        let mut c = Checks::default();
        let repo = env.repo.to_str().unwrap().to_string();
        c.check("--repo from a different folder: exit 0", 0, env.run_in(&env.dir, &["--repo", &repo]).code);

        gql(&env, 5, plain);
        env.run(&["--mr", "5"]);
        let run = env.run(&["--mr", "5", "--deadline", "1"]);
        c.check("stack: --deadline is unknown", "1 watch-gitlab: unexpected argument: --deadline",
            format!("{} {}{}", run.code, run.out, run.err));

        let run = env.run_in(&env.dir, &["--bogus"]);
        c.check("unexpected argument: exit 1", 1, run.code);
        c.check("unexpected argument: message", "watch-gitlab: unexpected argument: --bogus", format!("{}{}", run.out, run.err));
        c
    })
}

#[test]
fn first_check_exit_0() {
    hub_basics().assert("first check: exit 0");
}

#[test]
fn first_check_no_events() {
    hub_basics().assert("first check: no events");
}

#[test]
fn first_check_state_saved() {
    hub_basics().assert("first check: state saved");
}

#[test]
fn new_to_do_item() {
    hub_basics().assert("new to-do item");
}

#[test]
fn same_to_do_item_no_events() {
    hub_basics().assert("same to-do item: no events");
}

#[test]
fn assigned_to_own_mr_no_events() {
    hub_basics().assert("assigned to own MR: no events");
}

#[test]
fn http_403_exit_5() {
    hub_basics().assert("HTTP 403: exit 5");
}

#[test]
fn http_403_message() {
    hub_basics().assert("HTTP 403: message");
}

#[test]
fn network_error_exit_4() {
    hub_basics().assert("network error: exit 4");
}

#[test]
fn other_error_exit_1() {
    hub_basics().assert("other error: exit 1");
}

#[test]
fn other_error_message() {
    hub_basics().assert("other error: message");
}

#[test]
fn glab_not_authenticated_exit_5() {
    hub_basics().assert("glab not authenticated: exit 5");
}

#[test]
fn glab_not_authenticated_message() {
    hub_basics().assert("glab not authenticated: message");
}

#[test]
fn scp_style_ssh_remote_same_project() {
    hub_basics().assert("scp-style SSH remote: same project");
}

#[test]
fn state_with_no_mrs_no_events_for_old_notes() {
    hub_notes().assert("state with no mrs: no events for old notes");
}

#[test]
fn commented_mrs_only_mrs_of_this_project() {
    hub_notes().assert("commented MRs: only MRs of this project");
}

#[test]
fn new_note_from_a_different_user() {
    hub_notes().assert("new note from a different user");
}

#[test]
fn long_note_one_line() {
    hub_notes().assert("long note: one line");
}

#[test]
fn long_note_detail_has_100_characters() {
    hub_notes().assert("long note: detail has 100 characters");
}

#[test]
fn same_updated_at_no_notes_call() {
    hub_notes().assert("same updated_at: no notes call");
}

#[test]
fn note_on_an_own_mr_no_events() {
    hub_notes().assert("note on an own MR: no events");
}

#[test]
fn own_mrs_no_own_mrs_call() {
    hub_notes().assert("own MRs: no own MRs call");
}

#[test]
fn to_do_item_on_an_own_mr_no_events() {
    hub_notes().assert("to-do item on an own MR: no events");
}

#[test]
fn commented_mrs_all_event_pages_one_call_for_each_100_mrs() {
    hub_event_pages().assert("commented MRs: all event pages, one call for each 100 MRs");
}

#[test]
fn hub_reactions_from_rest_not_graphql() {
    hub_reactions().assert("hub: reactions from REST, not GraphQL");
}

#[test]
fn hub_reaction_on_an_own_comment_not_own_reactions_or_reactions_on_other_comments() {
    hub_reactions().assert("hub: reaction on an own comment, not own reactions or reactions on other comments");
}

#[test]
fn hub_same_reaction_no_events() {
    hub_reactions().assert("hub: same reaction: no events");
}

#[test]
fn default_branch_pipeline_ref_and_scope() {
    default_pipeline().assert("default branch pipeline: ref and scope");
}

#[test]
fn state_with_no_default_pipeline_no_events() {
    default_pipeline().assert("state with no default pipeline: no events");
}

#[test]
fn default_branch_pipeline_failed() {
    default_pipeline().assert("default branch pipeline failed");
}

#[test]
fn same_default_branch_pipeline_no_events() {
    default_pipeline().assert("same default branch pipeline: no events");
}

#[test]
fn default_branch_pipeline_passed_no_events() {
    default_pipeline().assert("default branch pipeline passed: no events");
}

#[test]
fn older_pipeline_during_a_retry_no_events() {
    default_pipeline().assert("older pipeline during a retry: no events");
}

#[test]
fn older_pipeline_during_a_retry_state_keeps_72() {
    default_pipeline().assert("older pipeline during a retry: state keeps 72");
}

#[test]
fn retried_pipeline_failed_again_no_events() {
    default_pipeline().assert("retried pipeline failed again: no events");
}

#[test]
fn failure_after_a_failure_previous_failed() {
    default_pipeline().assert("failure after a failure: previous failed");
}

#[test]
fn failure_after_a_pass_previous_success() {
    default_pipeline().assert("failure after a pass: previous success");
}

#[test]
fn saved_null_pipeline_event_with_previous_null() {
    default_pipeline().assert("saved null pipeline: event with previous null");
}

#[test]
fn default_failed_jobs() {
    default_pipeline().assert("default-failed: jobs");
}

#[test]
fn open_mrs_newest_first() {
    opened_mrs().assert("open MRs: newest first");
}

#[test]
fn state_with_no_open_mrs_no_events_for_open_mrs() {
    opened_mrs().assert("state with no open MRs: no events for open MRs");
}

#[test]
fn new_mr_of_a_different_user_not_own_mrs() {
    opened_mrs().assert("new MR of a different user, not own MRs");
}

#[test]
fn same_open_mrs_no_events() {
    opened_mrs().assert("same open MRs: no events");
}

#[test]
fn skip_mr_only_the_review_request_and_opened() {
    skip_mr().assert("--skip-mr: only the review request and opened");
}

#[test]
fn stack_first_check_exit_0() {
    stack_basics().assert("stack: first check: exit 0");
}

#[test]
fn stack_first_check_no_events() {
    stack_basics().assert("stack: first check: no events");
}

#[test]
fn stack_own_state_file() {
    stack_basics().assert("stack: own state file");
}

#[test]
fn mr_cache_second_fetch_reads_the_cache() {
    stack_basics().assert("MR cache: second fetch reads the cache");
}

#[test]
fn mr_cache_file_written() {
    stack_basics().assert("MR cache: file written");
}

#[test]
fn mr_cache_the_mr_of_a_different_project_is_not_read() {
    stack_basics().assert("MR cache: the MR of a different project is not read");
}

#[test]
fn stack_pipeline_failed() {
    stack_basics().assert("stack: pipeline failed");
}

#[test]
fn stack_same_pipeline_no_events() {
    stack_basics().assert("stack: same pipeline: no events");
}

#[test]
fn stack_running_pipeline_no_events() {
    stack_basics().assert("stack: running pipeline: no events");
}

#[test]
fn stack_pipeline_passed_iid_with() {
    stack_basics().assert("stack: pipeline passed, iid with !");
}

#[test]
fn pipeline_failed_jobs() {
    stack_basics().assert("pipeline failed: jobs");
}

#[test]
fn pipeline_passed_no_jobs() {
    stack_basics().assert("pipeline passed: no jobs");
}

#[test]
fn stack_approved() {
    stack_basics().assert("stack: approved");
}

#[test]
fn stack_unapproved() {
    stack_basics().assert("stack: unapproved");
}

#[test]
fn stack_own_approval_no_events() {
    stack_basics().assert("stack: own approval: no events");
}

#[test]
fn stack_own_approval_removed_no_events() {
    stack_basics().assert("stack: own approval removed: no events");
}

#[test]
fn stack_conflict() {
    stack_basics().assert("stack: conflict");
}

#[test]
fn stack_transient_status_no_events() {
    stack_basics().assert("stack: transient status: no events");
}

#[test]
fn stack_transient_status_old_conflict_value_stays() {
    stack_basics().assert("stack: transient status: old conflict value stays");
}

#[test]
fn stack_mergeable_with_open_threads() {
    stack_basics().assert("stack: mergeable with open threads");
}

#[test]
fn stack_old_comments_of_a_new_mr_no_events() {
    stack_comments().assert("stack: old comments of a new MR: no events");
}

#[test]
fn stack_new_comment_and_its_thread() {
    stack_comments().assert("stack: new comment and its thread");
}

#[test]
fn stack_own_reply() {
    stack_comments().assert("stack: own reply");
}

#[test]
fn stack_resolved_thread_and_system_note_no_unaddressed_line_for_them() {
    stack_comments().assert("stack: resolved thread and system note: no unaddressed line for them");
}

#[test]
fn stack_one_reaction_call_for_each_comment_none_for_a_system_note() {
    stack_comments().assert("stack: one reaction call for each comment, none for a system note");
}

#[test]
fn stack_reactions_on_the_mr_and_on_an_own_comment_not_own_reactions() {
    stack_reactions().assert("stack: reactions on the MR and on an own comment, not own reactions");
}

#[test]
fn stack_same_reactions_no_events() {
    stack_reactions().assert("stack: same reactions: no events");
}

#[test]
fn stack_merged() {
    stack_reactions().assert("stack: merged");
}

#[test]
fn stack_closed() {
    stack_ends().assert("stack: closed");
}

#[test]
fn stack_own_close() {
    stack_ends().assert("stack: own close");
}

#[test]
fn stack_own_merge() {
    stack_ends().assert("stack: own merge");
}

#[test]
fn stack_marked_as_draft() {
    stack_draft().assert("stack: marked as draft");
}

#[test]
fn stack_own_ready_no_events() {
    stack_draft().assert("stack: own ready: no events");
}

#[test]
fn stack_draft_with_no_system_note() {
    stack_draft().assert("stack: draft with no system note");
}

#[test]
fn stack_title_description_and_labels_changed() {
    stack_title().assert("stack: title, description, and labels changed");
}

#[test]
fn stack_own_title_description_and_label_changes_no_events() {
    stack_title().assert("stack: own title, description, and label changes: no events");
}

#[test]
fn stack_two_mrs_in_the_order_of_the_options() {
    stack_pages().assert("stack: two MRs in the order of the options");
}

#[test]
fn stack_comment_on_the_second_page_of_discussions() {
    stack_pages().assert("stack: comment on the second page of discussions");
}

#[test]
fn stack_comments_that_the_token_cannot_read_exit_5() {
    stack_errors().assert("stack: comments that the token cannot read: exit 5");
}

#[test]
fn stack_comments_that_the_token_cannot_read_message() {
    stack_errors().assert("stack: comments that the token cannot read: message");
}

#[test]
fn stack_http_403_on_discussions_message() {
    stack_errors().assert("stack: HTTP 403 on discussions: message");
}

#[test]
fn stack_unknown_mr_exit_5() {
    stack_errors().assert("stack: unknown MR: exit 5");
}

#[test]
fn stack_unknown_mr_message() {
    stack_errors().assert("stack: unknown MR: message");
}

#[test]
fn stack_graphql_error_exit_5() {
    stack_errors().assert("stack: GraphQL error: exit 5");
}

#[test]
fn stack_graphql_error_message() {
    stack_errors().assert("stack: GraphQL error: message");
}

#[test]
fn stack_bad_mr_message() {
    stack_errors().assert("stack: bad MR: message");
}

#[test]
fn review_no_mr_message() {
    stack_errors().assert("review: no --mr: message");
}

#[test]
fn review_two_mr_message() {
    stack_errors().assert("review: two --mr: message");
}

#[test]
fn review_first_check_no_events() {
    review_pushes().assert("review: first check: no events");
}

#[test]
fn review_own_state_file() {
    review_pushes().assert("review: own state file");
}

#[test]
fn review_no_stack_state_file() {
    review_pushes().assert("review: no stack state file");
}

#[test]
fn review_diffrefs_after_no_diffrefs_no_events() {
    review_pushes().assert("review: diffRefs after no diffRefs: no events");
}

#[test]
fn review_pushed() {
    review_pushes().assert("review: pushed");
}

#[test]
fn review_pushed_after_a_rebase() {
    review_pushes().assert("review: pushed after a rebase");
}

#[test]
fn review_fresh_old_state_not_used_exit_0_and_no_events() {
    review_pushes().assert("review: --fresh: old state not used, exit 0 and no events");
}

#[test]
fn review_fresh_new_state_saved() {
    review_pushes().assert("review: --fresh: new state saved");
}

#[test]
fn stack_push_no_events() {
    stack_push().assert("stack: push: no events");
}

#[test]
fn review_resolved_only_threads_that_the_user_started() {
    review_threads().assert("review: resolved, only threads that the user started");
}

#[test]
fn review_same_resolved_thread_no_events() {
    review_threads().assert("review: same resolved thread: no events");
}

#[test]
fn review_thread_resolved_by_the_user_no_events() {
    review_threads().assert("review: thread resolved by the user: no events");
}

#[test]
fn review_unaddressed_only_for_threads_with_a_note_from_the_user() {
    review_threads().assert("review: unaddressed only for threads with a note from the user");
}

#[test]
fn stack_needs_failed_pipeline_and_an_open_thread() {
    needs().assert("stack needs: failed pipeline and an open thread");
}

#[test]
fn stack_needs_mergeable_mr_is_ready() {
    needs().assert("stack needs: mergeable MR is ready");
}

#[test]
fn stack_needs_a_transient_merge_status_keeps_ready() {
    needs().assert("stack needs: a transient merge status keeps ready");
}

#[test]
fn stack_needs_need_rebase_is_a_conflict() {
    needs().assert("stack needs: need_rebase is a conflict");
}

#[test]
fn stack_needs_worst_over_two_mrs() {
    needs().assert("stack needs: worst over two MRs");
}

#[test]
fn stack_needs_a_merged_mr_needs_nothing() {
    needs().assert("stack needs: a merged MR needs nothing");
}

#[test]
fn review_needs_a_push_after_the_first_check_gives_commits() {
    needs().assert("review needs: a push after the first check gives commits");
}

#[test]
fn review_needs_a_comment_of_the_user_after_the_push_clears_commits() {
    needs().assert("review needs: a comment of the user after the push clears commits");
}

#[test]
fn review_needs_an_approval_of_the_user_after_the_push_clears_commits() {
    needs().assert("review needs: an approval of the user after the push clears commits");
}

#[test]
fn hub_needs_pending_to_do_and_failed_default_pipeline() {
    needs().assert("hub needs: pending to-do and failed default pipeline");
}

#[test]
fn stack_needs_nothing() {
    needs().assert("stack needs: nothing");
}

#[test]
fn todo_item_key() {
    present().assert("todo: item key");
}

#[test]
fn todo_present() {
    present().assert("todo: present");
}

#[test]
fn todo_done_not_present() {
    present().assert("todo done: not present");
}

#[test]
fn note_item_key() {
    present().assert("note: item key");
}

#[test]
fn note_present() {
    present().assert("note: present");
}

#[test]
fn own_reply_note_not_present() {
    present().assert("own reply: note not present");
}

#[test]
fn resolved_note_not_present() {
    present().assert("resolved: note not present");
}

#[test]
fn default_failed_item_key() {
    present().assert("default-failed: item key");
}

#[test]
fn default_failed_present() {
    present().assert("default-failed: present");
}

#[test]
fn default_passed_not_present() {
    present().assert("default passed: not present");
}

#[test]
fn comment_and_unaddressed_one_item_key() {
    present().assert("comment and unaddressed: one item key");
}

#[test]
fn unaddressed_thread_present() {
    present().assert("unaddressed thread: present");
}

#[test]
fn answered_thread_not_present() {
    present().assert("answered thread: not present");
}

#[test]
fn pipeline_failed_present() {
    present().assert("pipeline failed: present");
}

#[test]
fn conflict_present() {
    present().assert("conflict: present");
}

#[test]
fn repo_from_a_different_folder_exit_0() {
    arguments().assert("--repo from a different folder: exit 0");
}

#[test]
fn stack_deadline_is_unknown() {
    arguments().assert("stack: --deadline is unknown");
}

#[test]
fn unexpected_argument_exit_1() {
    arguments().assert("unexpected argument: exit 1");
}

#[test]
fn unexpected_argument_message() {
    arguments().assert("unexpected argument: message");
}
