mod support;

use std::io::{BufRead, Write};
use std::process::Command;
use std::time::Instant;

use serde_json::{Value, json};
use support::daemon::{Watchd, end, ev, norow, wait_for};

/// Sends one request line to the daemon socket and returns the answer.
fn raw_request(w: &Watchd, request: &Value) -> Value {
    let mut stream = std::os::unix::net::UnixStream::connect(w.watchd.join("daemon.sock")).unwrap();
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(15)))
        .unwrap();
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    let mut answer = String::new();
    std::io::BufReader::new(&stream).read_line(&mut answer).unwrap();
    serde_json::from_str(&answer).unwrap()
}

#[test]
fn watch_exits_0_at_once_and_writes_the_record_with_the_session() {
    let w = Watchd::new();
    let started = Instant::now();

    let run = w.watch(&["--interval", "600"]);

    assert_eq!(run.code, 0, "{}", run.err);
    assert!(started.elapsed().as_secs() <= 10, "{:?}", started.elapsed());
    let sub = w.sub_of("app");
    assert_eq!(sub["session"], json!(w.session_id()), "{sub}");
    assert!(sub.get("session_pid").is_none(), "{sub}");
}

#[test]
fn watch_fresh_deletes_the_engine_state() {
    let w = Watchd::new();
    w.env.write_engine_state("app", r#"{"todos": []}"#);
    w.fake("app", "sleep", "5");

    let run = w.watch(&["--fresh"]);

    assert_eq!(run.code, 0, "{}", run.err);
    assert!(!w.env.engine_state("app").exists());
}

#[test]
fn wait_gives_the_events_of_all_keys_of_the_session_with_key_and_mode() {
    let w = Watchd::new();
    let review = format!("{}-review-5", w.author_key());
    w.events("app", &[ev("todo", 6)]);
    w.events(&review, &[ev("comment", 5)]);
    assert_eq!(w.watch(&[]).code, 0);
    assert_eq!(w.watch(&["--review", "--mr", "5"]).code, 0);
    let filled = wait_for(10, || !w.inbox_of("app").is_empty() && !w.inbox_of(&review).is_empty());
    let mode = w.state()["subs"][&review]["mode"].clone();

    let run = w.wait();

    assert!(filled, "{}", w.state()["inbox"]);
    assert_eq!(mode, json!("review"));
    let lines: Vec<&str> = run.out.lines().collect();
    assert_eq!((run.code, lines.len()), (0, 2), "{}\n{}", run.out, run.err);
    assert!(
        lines[0].starts_with(r#"{"key":"app","mode":"hub","kind":"todo""#),
        "{}",
        lines[0]
    );
    let prefix = format!(r#"{{"key":"{review}","mode":"review","kind":"comment""#);
    assert!(lines[1].starts_with(&prefix), "{}", lines[1]);
}

#[test]
fn wait_with_no_watch_exits_0_with_no_output() {
    let w = Watchd::new();
    let started = Instant::now();

    let run = w.run(w.as_session(w.wait_command(), "new-session", w.session_pid()));

    assert_eq!((run.code, run.out.as_str(), run.err.as_str()), (0, "", ""));
    assert!(started.elapsed().as_secs() <= 10, "{:?}", started.elapsed());
}

#[test]
fn wait_after_a_permanent_error_exits_1_with_the_error_text() {
    let w = Watchd::new();
    w.fake("app", "exit", "5\n");
    w.fake("app", "err", "watchd: HTTP 403 on todos\n");
    assert_eq!(w.watch(&[]).code, 0);

    let first = w.wait();
    let second = w.wait();

    assert_eq!((first.code, first.err.as_str()), (1, "watchd: HTTP 403 on todos"));
    assert_eq!((second.code, second.out.as_str(), second.err.as_str()), (0, "", ""));
}

#[test]
fn wait_after_an_error_with_events_in_the_inbox_gives_the_error_then_the_events() {
    let w = Watchd::new();
    w.events("app", &[ev("todo", 5)]);
    assert_eq!(w.watch(&["--interval", "1"]).code, 0);
    let filled = wait_for(10, || !w.inbox_of("app").is_empty());
    w.fake("app", "err", "watchd: HTTP 403 on todos\n");
    w.fake("app", "exit", "5\n");
    let ended = wait_for(10, || !w.has_sub("app"));

    let first = w.wait();
    let second = w.wait();

    assert!(filled && ended, "{}", w.log());
    assert_eq!((first.code, first.err.as_str()), (1, "watchd: HTTP 403 on todos"));
    assert_eq!((second.code, norow(&second.out)), (0, ev("todo", 5)), "{}", second.err);
}

#[test]
fn wait_after_all_mrs_merged_gives_the_merged_events() {
    let w = Watchd::new();
    let author = w.author_key();
    w.events(&author, &[ev("merged", 5)]);
    assert_eq!(w.watch(&["--mr", "5"]).code, 0);
    let ended = wait_for(10, || !w.has_sub(&author));

    let first = w.wait();
    let second = w.wait();

    assert!(ended, "{}", w.log());
    assert_eq!((first.code, norow(&first.out)), (0, ev("merged", 5)), "{}", first.err);
    assert_eq!((second.code, second.out.as_str(), second.err.as_str()), (0, "", ""));
}

#[test]
fn wait_adds_no_repo() {
    let w = Watchd::new();
    let other = w.env.dir.join("other");
    w.env.git_repo(&other, "https://gitlab.example.com/group/sub/other.git");
    let mut command = w.wait_command();
    command.current_dir(&other);

    let run = w.run(command);

    assert_eq!(run.code, 0, "{}", run.err);
    let repos = std::fs::read_to_string(w.watchd.join("repos.json")).unwrap_or_default();
    assert!(!repos.contains(other.to_str().unwrap()), "{repos}");
}

#[test]
fn session_id_with_a_slash_is_an_error() {
    let w = Watchd::new();

    let run = w.run(w.as_session(w.watch_command(&[]), "a/b", w.session_pid()));

    assert_eq!((run.code, run.err.as_str()), (1, "watchd: --session needs an ID"));
}

#[test]
fn the_daemon_answers_a_request_with_a_bad_session_id_with_the_error() {
    let w = Watchd::new();
    let follow = w.follower(&w.env.dir);
    let requests = [
        json!({"type": "wait", "session": "../x", "owner_pid": w.session_pid()}),
        json!({
            "type": "watch", "key": "app", "slug": "app", "repo": w.env.repo, "mode": "hub", "mrs": [],
            "interval": 1, "session": "../x", "fresh": false,
        }),
        json!({"type": "unsubscribe", "key": "app", "slug": "app", "mode": "hub", "session": ""}),
    ];

    let answers: Vec<Value> = requests.iter().map(|request| raw_request(&w, request)).collect();

    let error = json!({"type": "error", "text": "watchd: --session needs an ID\n"});
    assert_eq!(answers, [error.clone(), error.clone(), error]);
    assert!(!w.watchd.join("x.json").exists());
    assert!(!w.has_sub("app"));
    end(follow);
}

#[test]
fn old_records_end_at_start_and_their_items_go_to_the_hub() {
    let w = Watchd::new();
    let author = w.author_key();
    for folder in ["subs", "items", "inbox"] {
        std::fs::create_dir_all(w.watchd.join(folder)).unwrap();
    }
    let sub = json!({
        "version": 3, "key": author, "slug": "app", "repo": w.env.repo, "mode": "author", "mrs": [5],
        "interval": 120, "session_pid": w.session_pid(), "client_pid": 1, "client_at": 0,
        "replaced_sessions": [], "ended_mrs": [],
    });
    std::fs::write(w.watchd.join(format!("subs/{author}.json")), sub.to_string()).unwrap();
    let items = json!({"next": 2, "items": [{"n": 1, "item": "thread:d1", "owner": "daemon", "iid": 5}]});
    std::fs::write(w.watchd.join(format!("items/{author}.json")), items.to_string()).unwrap();
    let owner = w.watchd.join(format!("inbox/{author}.owner"));
    std::fs::write(&owner, format!("{}\n", w.session_pid())).unwrap();

    let follow = w.follower(&w.env.dir);
    let ended = wait_for(10, || w.log_count("subscription removed: old format") == 1);
    let status = w.client(&["status"]);

    assert!(ended, "{}", w.log());
    assert!(!status.out.contains(&author), "{}", status.out);
    let hub: Vec<Value> = w.items_of("app")["items"].as_array().cloned().unwrap_or_default();
    let names: Vec<&Value> = hub.iter().map(|item| &item["item"]).collect();
    assert_eq!(names, [&json!("thread:d1")]);
    assert!(!owner.exists());
    end(follow);
}

#[test]
fn subscribe_request_gets_the_error_text() {
    let w = Watchd::new();
    let follow = w.follower(&w.env.dir);
    let line = json!({
        "type": "subscribe", "key": "app", "slug": "app", "repo": w.env.repo, "mode": "hub",
        "mrs": [], "interval": 1, "session_pid": w.session_pid(), "client_pid": std::process::id(),
        "herdr_workspace": "w1", "once": false, "fresh": false, "again": false, "poke_token": "t",
    });

    let answer = raw_request(&w, &line);

    assert_eq!(
        answer,
        json!({"type": "error", "text": "watchd: this watch client is older than the daemon. Start the watch again.\n"})
    );
    end(follow);
}

/// A `wait` of the session `id` with the owner of the test session and `--rename-owner-session`.
fn rename_wait(w: &Watchd, id: &str) -> Command {
    let mut command = w.as_session(w.wait_command(), id, w.session_pid());
    command.arg("--rename-owner-session");
    command
}

#[test]
fn a_wait_with_a_new_id_and_the_same_owner_takes_the_watches_of_the_old_id() {
    let w = Watchd::new();
    let old = w.session_id();
    assert_eq!(w.watch(&[]).code, 0);
    let first = w.start(w.wait_command());
    let connected = wait_for(10, || w.waiting(&old));

    let second = w.start(rename_wait(&w, "cleared"));
    let first = first.wait(10).expect("the waiter of the old ID exits");
    let taken = wait_for(10, || w.sub_of("app")["session"] == json!("cleared"));
    w.events("app", &[ev("todo", 5)]);
    let second = second.wait(10).expect("the waiter of the new ID exits");

    assert!(connected, "{}", w.state());
    assert_eq!((first.code, first.out.as_str(), first.err.as_str()), (0, "", ""));
    assert!(taken, "{}", w.state());
    let sessions = w.state()["sessions"].clone();
    assert!(
        !sessions[&old].is_object() && sessions["cleared"].is_object(),
        "{sessions}"
    );
    assert_eq!((second.code, norow(&second.out)), (0, ev("todo", 5)), "{}", second.err);
}

#[test]
fn a_wait_with_a_new_id_and_the_same_owner_and_no_rename_flag_takes_no_watch() {
    let w = Watchd::new();
    let old = w.session_id();
    assert_eq!(w.watch(&[]).code, 0);
    let first = w.start(w.wait_command());
    let connected = wait_for(10, || w.waiting(&old));

    let other = w.run(w.as_session(w.wait_command(), "resumed", w.session_pid()));
    w.events("app", &[ev("todo", 5)]);
    let first = first.wait(10).expect("the waiter of the old ID exits");

    assert!(connected, "{}", w.state());
    assert_eq!((other.code, other.out.as_str(), other.err.as_str()), (0, "", ""));
    assert_eq!(w.sub_of("app")["session"], json!(old));
    assert_eq!((first.code, norow(&first.out)), (0, ev("todo", 5)), "{}", first.err);
}

#[test]
fn a_rename_wait_takes_no_watch_of_an_away_session_with_the_same_owner_pid() {
    let w = Watchd::new();
    let old = w.session_id();
    assert_eq!(w.watch(&[]).code, 0);
    let record = w.watchd.join(format!("sessions/{old}.json"));
    let now = std::time::UNIX_EPOCH.elapsed().unwrap().as_secs();
    let away = json!({"version": 4, "owner_pid": w.session_pid(), "owner_gone_at": now, "replaced": [], "ended": []});
    let temp = record.with_extension("tmp");
    std::fs::write(&temp, away.to_string()).unwrap();
    std::fs::rename(&temp, &record).unwrap();

    let run = w.run(rename_wait(&w, "cleared"));

    assert_eq!((run.code, run.out.as_str(), run.err.as_str()), (0, "", ""));
    assert_eq!(w.sub_of("app")["session"], json!(old));
    let sessions = w.state()["sessions"].clone();
    assert_eq!(sessions[&old]["owner_gone_at"], json!(now), "{sessions}");
}

#[test]
fn a_second_session_takes_the_key_and_the_first_gets_one_replaced_event() {
    let w = Watchd::new();
    assert_eq!(w.watch(&[]).code, 0);

    let second = w.run(w.as_session(w.watch_command(&[]), "second", w.session_pid()));
    let first = w.wait();
    let again = w.wait();

    assert_eq!(second.code, 0, "{}", second.err);
    assert_eq!(
        (first.code, first.out.as_str()),
        (0, r#"{"kind":"replaced","key":"app","mode":"hub"}"#),
        "{}",
        first.err
    );
    assert_eq!((again.code, again.out.as_str(), again.err.as_str()), (0, "", ""));
}

#[test]
fn a_session_that_takes_its_key_back_gets_no_replaced_event() {
    let w = Watchd::new();
    assert_eq!(w.watch(&[]).code, 0);
    let second = w.run(w.as_session(w.watch_command(&[]), "second", w.session_pid()));
    w.events("app", &[ev("todo", 5)]);

    let back = w.watch(&[]);
    let first = w.wait();
    let other = w.run(w.as_session(w.wait_command(), "second", w.session_pid()));

    assert_eq!((second.code, back.code), (0, 0), "{}\n{}", second.err, back.err);
    assert_eq!((first.code, norow(&first.out)), (0, ev("todo", 5)), "{}", first.err);
    assert_eq!(
        (other.code, other.out.as_str()),
        (0, r#"{"kind":"replaced","key":"app","mode":"hub"}"#),
        "{}",
        other.err
    );
}
