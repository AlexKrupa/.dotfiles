mod support;

use serde_json::Value;
use support::daemon::{Watchd, ev, sleep, wait_for};

fn comment(iid: u64) -> String {
    serde_json::json!({"kind": "comment", "iid": iid, "title": "Add foo", "url": "u", "actor": "anna",
        "detail": "Why?", "branch": "b", "item": "thread:d1"})
    .to_string()
}

fn views(output: &std::path::Path, key: &str) -> Vec<Value> {
    std::fs::read_to_string(output)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|line| line["type"] == "view" && line["key"] == key)
        .collect()
}

fn row_kinds(view: &Value) -> Vec<String> {
    view["branches"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|branch| branch["rows"].as_array().cloned().unwrap_or_default())
        .map(|row| support::raw(&row["kind"]))
        .collect()
}

/// An author watch whose delivery has one comment, and a report of it.
fn reported_comment(w: &Watchd) -> String {
    let author = w.author_key();
    w.fake(&author, "state", r#"{"version": 4, "present": ["thread:d1"]}"#);
    w.events(&author, &[comment(5)]);
    assert_eq!(w.watch_wait(&["--mr", "5"]).code, 0);
    assert_eq!(w.report("{}", &["--mr", "5"]).code, 0);
    author
}

#[test]
fn follow_gets_a_view_after_an_event() {
    let w = Watchd::new();
    let author = reported_comment(&w);

    let (_follower, output) = w.spawn_logged(follower(&w), "follow.out");
    let found = wait_for(10, || {
        views(&output, &author).iter().any(|view| !row_kinds(view).is_empty())
    });

    assert!(found, "{}", std::fs::read_to_string(&output).unwrap_or_default());
    let view = views(&output, &author).pop().unwrap();
    assert_eq!(view["branches"].as_array().map(Vec::len), Some(1), "{view}");
    assert_eq!(row_kinds(&view), ["comment"]);
}

#[test]
fn follow_sends_a_changed_view_only_once() {
    let w = Watchd::new();
    let author = reported_comment(&w);

    let (_follower, output) = w.spawn_logged(follower(&w), "follow.out");
    wait_for(10, || {
        views(&output, &author).iter().any(|view| !row_kinds(view).is_empty())
    });
    let before = views(&output, &author).len();
    sleep(2);

    assert!(before > 0, "{}", std::fs::read_to_string(&output).unwrap_or_default());
    assert_eq!(views(&output, &author).len(), before);
}

fn approved(iid: u64) -> String {
    serde_json::json!({"kind": "approved", "iid": iid, "title": "Add foo", "url": "u", "actor": "bob",
        "detail": "approved", "branch": "b"})
    .to_string()
}

fn wait_limited(w: &Watchd, seconds: u64) -> support::Run {
    support::daemon::run_limited(w.wait_command(), &w.env.dir, seconds)
}

fn view_with(output: &std::path::Path, key: &str, kinds: &[&str]) -> bool {
    wait_for(10, || {
        views(output, key)
            .last()
            .is_some_and(|view| kinds.iter().all(|kind| row_kinds(view).contains(&kind.to_string())))
    })
}

#[test]
fn an_approval_reaches_the_view_and_not_the_agent() {
    let w = Watchd::new();
    let author = reported_comment(&w);
    let (_follower, output) = w.spawn_logged(follower(&w), "follow.out");

    w.events(&author, &[approved(5)]);
    let wait = wait_limited(&w, 2);
    let found = view_with(&output, &author, &["review"]);

    assert!(found, "{}", std::fs::read_to_string(&output).unwrap_or_default());
    assert_eq!(wait.code, 124, "wait got: {}", wait.out);
}

#[test]
fn a_comment_wakes_and_an_approval_waits_for_the_report() {
    let w = Watchd::new();
    let author = w.author_key();
    w.fake(&author, "state", r#"{"version": 4, "present": ["thread:d1"]}"#);
    assert_eq!(w.watch(&["--mr", "5"]).code, 0);
    let (_follower, output) = w.spawn_logged(follower(&w), "follow.out");

    w.events(&author, &[comment(5), approved(5)]);
    let wait = w.wait();
    assert_eq!(w.report("{}", &["--mr", "5"]).code, 0);

    assert_eq!(support::each(&wait.out, "kind"), "comment");
    assert!(
        view_with(&output, &author, &["comment", "review"]),
        "{}",
        std::fs::read_to_string(&output).unwrap_or_default()
    );
}

fn artifact(w: &Watchd, args: &[&str]) -> support::Run {
    w.client_in(&w.env.repo, &[&["artifact"][..], args].concat())
}

#[test]
fn artifact_shows_in_the_view() {
    let w = Watchd::new();
    let author = reported_comment(&w);
    let (_follower, output) = w.spawn_logged(follower(&w), "follow.out");
    // The default branch of an artifact is the branch that the local round read.
    wait_for(10, || w.worktree_state(&w.env.repo)["branch"] == "main");

    let run = artifact(&w, &["spec", "/x/spec.md"]);
    let found = wait_for(10, || {
        views(&output, &author).last().is_some_and(|view| {
            view["branches"][0]["artifacts"].as_array().is_some_and(|list| {
                list.iter()
                    .any(|item| item["kind"] == "spec" && item["target"] == "/x/spec.md")
            })
        })
    });

    assert_eq!(run.code, 0, "{}", run.err);
    assert!(found, "{}", std::fs::read_to_string(&output).unwrap_or_default());
}

#[test]
fn mr_draft_title_names_a_branch_with_no_mr() {
    let w = Watchd::new();
    let author = reported_comment(&w);
    let (_follower, output) = w.spawn_logged(follower(&w), "follow.out");
    let draft = w.env.dir.join("draft.md");
    std::fs::write(&draft, "Notes\n# Show sync\n\nBody\n").unwrap();

    let run = artifact(&w, &["MR draft", draft.to_str().unwrap(), "--branch", "main"]);
    let titled = wait_for(10, || {
        views(&output, &author).last().is_some_and(|view| {
            view["branches"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|branch| branch["title"] == "Show sync")
        })
    });

    assert_eq!(run.code, 0, "{}", run.err);
    assert!(titled, "{}", std::fs::read_to_string(&output).unwrap_or_default());
}

#[test]
fn artifact_outside_a_worktree_fails_with_the_folder() {
    let w = Watchd::new();
    let outside = w.env.dir.join("outside");
    std::fs::create_dir_all(&outside).unwrap();

    let run = w.client_in(&outside, &["artifact", "spec", "/x/spec.md"]);

    assert_eq!(run.code, 1);
    assert!(run.err.contains("not a git worktree"), "{}", run.err);
}

#[test]
fn rows_prints_the_view() {
    let w = Watchd::new();
    reported_comment(&w);

    let run = w.client_in(&w.env.repo, &["rows", "--mr", "5"]);

    assert_eq!(run.code, 0, "{}", run.err);
    assert!(
        run.out
            .lines()
            .any(|line| line.starts_with("  1  comment  @anna: \"Why?\"")),
        "{}",
        run.out
    );
}

#[test]
fn rows_prints_nothing_with_no_view() {
    let w = Watchd::new();
    let outside = w.env.dir.join("other");
    w.env
        .git_repo(&outside, "https://gitlab.example.com/group/sub/other.git");

    let run = w.client_in(&outside, &["rows"]);

    assert_eq!((run.code, run.out.as_str()), (0, ""), "{}", run.err);
}

#[test]
fn report_prints_nothing_without_print() {
    let w = Watchd::new();
    let author = w.author_key();
    w.fake(&author, "state", r#"{"version": 4, "present": ["thread:d1"]}"#);
    w.events(&author, &[comment(5)]);
    assert_eq!(w.watch_wait(&["--mr", "5"]).code, 0);

    let quiet = w.report("{}", &["--mr", "5"]);
    let printed = w.report("{}", &["--mr", "5", "--print"]);

    assert_eq!((quiet.code, quiet.out.as_str()), (0, ""));
    assert!(printed.out.contains("Why?"), "{}", printed.out);
}

fn unaddressed(iid: u64) -> String {
    serde_json::json!({"kind": "unaddressed", "iid": iid, "title": "Add foo", "url": "u", "actor": "anna",
        "detail": "Why?", "branch": "b", "item": "thread:d1"})
    .to_string()
}

#[test]
fn a_comment_wakes_after_a_round_that_handled_its_thread_row() {
    let w = Watchd::new();
    let author = reported_comment(&w);
    let pushed = r#"{"kind":"pushed","iid":5,"title":"Add foo","url":"u","actor":"","detail":"pushed","branch":"b"}"#;

    w.events(&author, &[pushed.to_string(), unaddressed(5)]);
    w.managed_rounds(2);
    w.events(&author, &[comment(5), unaddressed(5)]);
    w.managed_rounds(2);
    let wait = w.wait();

    assert!(support::each(&wait.out, "kind").contains("comment"), "{}", wait.out);
}

#[test]
fn a_handled_thread_row_keeps_its_comment_that_waits_in_the_inbox() {
    let w = Watchd::new();
    let author = reported_comment(&w);
    let other = serde_json::json!({"kind": "comment", "iid": 5, "title": "Add foo", "url": "u", "actor": "bob",
        "detail": "And this?", "branch": "b", "item": "thread:d2"})
    .to_string();

    w.events(&author, &[comment(5)]);
    w.managed_rounds(2);
    w.events(&author, &[unaddressed(5), other]);
    w.managed_rounds(2);
    let wait = w.wait();

    assert!(wait.out.contains("Why?"), "{}", wait.out);
    assert!(wait.out.contains("And this?"), "{}", wait.out);
}

#[test]
fn a_review_watch_has_a_review_view_in_place_of_the_author_view() {
    let w = Watchd::new();
    let review = format!("{}-review-5", w.author_key());
    w.fake(&review, "state", r#"{"version": 4, "present": []}"#);
    assert_eq!(w.watch(&["--review", "--mr", "5"]).code, 0);

    let (_follower, output) = w.spawn_logged(follower(&w), "follow.out");
    let found = wait_for(10, || !views(&output, &review).is_empty());

    assert!(found, "{}", std::fs::read_to_string(&output).unwrap_or_default());
    assert!(views(&output, &w.author_key()).is_empty());
}

#[test]
fn a_hub_watch_has_a_hub_view() {
    let w = Watchd::new();
    assert_eq!(w.watch(&[]).code, 0);

    let (_follower, output) = w.spawn_logged(follower(&w), "follow.out");
    let found = wait_for(10, || !views(&output, "app").is_empty());

    assert!(found, "{}", std::fs::read_to_string(&output).unwrap_or_default());
    assert_eq!(views(&output, "app")[0]["hub"], true);
}

#[test]
fn a_bump_worktree_wakes_for_a_passed_pipeline() {
    let w = Watchd::new();
    let review = format!("{}-review-5", w.author_key());
    w.fake(&review, "state", r#"{"version": 4, "present": []}"#);
    assert_eq!(w.client_in(&w.env.repo, &["kind", "bump"]).code, 0);
    w.events(&review, &[ev("pipeline", 5)]);

    let wait = w.watch_wait(&["--review", "--mr", "5"]);

    assert_eq!(support::each(&wait.out, "kind"), "pipeline", "{}", wait.out);
}

fn follower(w: &Watchd) -> std::process::Command {
    let mut command = w.command();
    command.current_dir(&w.env.repo).arg("follow");
    command
}
