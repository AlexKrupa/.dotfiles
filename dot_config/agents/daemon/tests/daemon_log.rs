mod support;

use std::sync::OnceLock;
use std::time::{Duration, SystemTime};

use serde_json::{Value, json};
use support::Checks;
use support::daemon::{Watchd, alive, end, ev, norm, sleep, wait_for};

fn fields(value: &Value, keys: &[&str]) -> String {
    Value::from(
        keys.iter()
            .map(|key| value.pointer(key).cloned().unwrap_or(Value::Null))
            .collect::<Vec<_>>(),
    )
    .to_string()
}

fn work_of(w: &Watchd) -> Value {
    let state = w.worktree_state(&w.env.repo);
    json!({"kind": state["kind"], "stage": state["stage"]})
}

fn kind(w: &Watchd, folder: &std::path::Path, args: &[&str]) -> support::Run {
    let mut command = w.command();
    command.current_dir(folder).arg("kind").args(args);
    let run = w.run(command);
    support::Run {
        out: [run.out, run.err].concat(),
        err: String::new(),
        code: run.code,
    }
}

fn write_work(w: &Watchd, work: Value) {
    let repo = &w.env.repo;
    std::fs::create_dir_all(&w.watchd).unwrap();
    let repos = json!({"version": 2, "repos": [repo]});
    std::fs::write(w.watchd.join("repos.json"), repos.to_string()).unwrap();
    let mut state = json!({"version": 2, "path": repo, "repo": repo, "branch": null, "key": "",
        "stack": [], "mrs": []});
    state.as_object_mut().unwrap().extend(work.as_object().unwrap().clone());
    let folder = w.watchd.join("worktrees");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(
        folder.join(format!("{}.json", support::hash12(repo))),
        state.to_string(),
    )
    .unwrap();
}

fn log_and_worktrees() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let mut c = Checks::default();
        let mut herdr = false;
        let repo_of = |w: &Watchd| w.env.repo.to_str().unwrap().to_string();

        let w = Watchd::new();
        w.events("app", &[ev("todo", 5)]);
        w.watch(&[]);
        c.check(
            "routed event: log line",
            r#"["event","app","todo","request"]"#,
            fields(&w.log_last(), &["/type", "/key", "/event/kind", "/sound"]),
        );
        w.events("app", &[ev("reaction", 5)]);
        w.watch(&[]);
        c.check("reaction: sound none", "none", support::raw(&w.log_last()["sound"]));
        w.client(&["unsubscribe", "--repo", &repo_of(&w)]);
        herdr |= w.herdr_called();
        drop(w);

        let w = Watchd::new();
        let stack = w.stack_key();
        w.events(&stack, &[ev("pipeline", 5)]);
        w.run(w.watch_command(&["--interval", "600", "--mr", "5"]));
        c.check(
            "a new record has no herdr workspace",
            "null",
            support::raw(&w.sub_of(&stack)["herdr_workspace"]),
        );
        w.events(&stack, &[ev("merged", 5)]);
        w.run(w.watch_command(&["--interval", "600", "--once", "--mr", "5"]));
        wait_for(5, || !w.has_sub(&stack));
        c.check(
            "all MRs merged: worktree stage done",
            "done",
            support::raw(&work_of(&w)["stage"]),
        );
        herdr |= w.herdr_called();
        drop(w);

        let w = Watchd::new();
        w.events(&w.stack_key(), &[ev("pipeline", 5)]);
        w.run(w.watch_command(&["--interval", "600", "--mr", "5"]));
        w.client(&["unsubscribe", "--repo", &repo_of(&w), "--mr", "5"]);
        c.check(
            "unsubscribe: worktree stage stopped",
            "stopped",
            support::raw(&work_of(&w)["stage"]),
        );
        herdr |= w.herdr_called();
        drop(w);

        let w = Watchd::new();
        w.fake("app", "exit", "5\n");
        w.fake("app", "err", "watchd: HTTP 403 on todos\n");
        w.watch(&[]);
        c.check(
            "permanent error: stopped line",
            r#"["stopped","watchd: HTTP 403 on todos",null]"#,
            fields(&w.log_last(), &["/type", "/error", "/title"]),
        );
        herdr |= w.herdr_called();
        drop(w);

        let w = Watchd::new();
        let stack = w.stack_key();
        w.fake(&stack, "state", r#"{"mrs": {"5": {"title": "Add foo"}}, "needs": []}"#);
        w.fake(&stack, "exit", "5\n");
        w.fake(&stack, "err", "watchd: HTTP 403 on graphql\n");
        w.watch(&["--mr", "5"]);
        c.check(
            "permanent error of a stack: stopped line has the MR title",
            r#"["stopped","Add foo"]"#,
            fields(&w.log_last(), &["/type", "/title"]),
        );
        herdr |= w.herdr_called();
        drop(w);

        let w = Watchd::new();
        let run = kind(&w, &w.env.dir, &["mine"]);
        let worktrees = w.state()["worktrees"]
            .as_object()
            .map_or(String::new(), |map| map.keys().cloned().collect::<Vec<_>>().join(" "));
        c.check(
            "kind outside a git repo does nothing",
            "0 ",
            format!("{} {worktrees}", run.code),
        );
        let run = kind(&w, &w.env.repo, &["review", "--workspace", "wT"]);
        c.check(
            "kind: writes the worktree state",
            format!("0 {}", norm(r#"{"kind":"review","stage":null}"#)),
            format!("{} {}", run.code, work_of(&w)),
        );
        let run = kind(&w, &w.env.repo, &["foo"]);
        c.check(
            "unknown kind",
            "1 watchd: unknown kind: foo",
            format!("{} {}", run.code, run.out),
        );
        herdr |= w.herdr_called();
        drop(w);

        let w = Watchd::new();
        write_work(&w, json!({"kind": "mine", "stage": "done"}));
        w.events(&w.stack_key(), &[ev("pipeline", 5)]);
        w.run(w.watch_command(&["--interval", "600", "--mr", "5"]));
        let run = kind(&w, &w.env.repo, &["review"]);
        c.check(
            "kind during a live watch keeps the stage",
            format!("0 {}", norm(r#"{"kind":"review","stage":"done"}"#)),
            format!("{} {}", run.code, work_of(&w)),
        );
        w.client(&["unsubscribe", "--repo", &repo_of(&w), "--mr", "5"]);
        herdr |= w.herdr_called();
        drop(w);

        for (name, expected, review, args) in [
            ("stack", "mine", false, &["--mr", "5"][..]),
            ("review", "review", true, &["--review", "--mr", "5"][..]),
            ("hub", "hub", false, &[][..]),
        ] {
            let w = Watchd::new();
            let key = match (review, args.is_empty()) {
                (true, _) => format!("{}-review-5", w.stack_key()),
                (false, true) => "app".to_string(),
                (false, false) => w.stack_key(),
            };
            w.events(&key, &[ev("comment", 5)]);
            let mut watch_args = vec!["--interval", "600"];
            watch_args.extend(args);
            w.run(w.watch_command(&watch_args));
            c.check(
                &format!("subscribe with no kind sets the kind of the mode: {name}"),
                expected,
                support::raw(&work_of(&w)["kind"]),
            );
            let mut unsubscribe = vec!["unsubscribe", "--repo"];
            let repo = repo_of(&w);
            unsubscribe.push(&repo);
            unsubscribe.extend(args);
            w.client(&unsubscribe);
            herdr |= w.herdr_called();
        }

        let w = Watchd::new();
        write_work(&w, json!({"kind": "bump"}));
        w.events(&w.stack_key(), &[ev("pipeline", 5)]);
        w.run(w.watch_command(&["--interval", "600", "--mr", "5"]));
        c.check(
            "subscribe keeps an existing kind",
            "bump",
            support::raw(&work_of(&w)["kind"]),
        );
        w.client(&["unsubscribe", "--repo", &repo_of(&w), "--mr", "5"]);
        herdr |= w.herdr_called();
        drop(w);

        let w = Watchd::new();
        let run = w.client(&["route", "--iid", "61", "--action", "bump"]);
        c.check(
            "route: log line",
            r#"0 ["route","app",61,"bump"]"#,
            format!(
                "{} {}",
                run.code,
                fields(&w.log_last(), &["/type", "/key", "/iid", "/action"])
            ),
        );
        let run = w.client(&["route", "--iid", "61", "--action", "merge"]);
        c.check(
            "route: unknown action",
            "1 watchd: unknown action: merge",
            format!("{} {}{}", run.code, run.out, run.err),
        );
        herdr |= w.herdr_called();

        c.check("no herdr call", "yes", if herdr { "no" } else { "yes" });
        c
    })
}

fn prune() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        std::fs::create_dir_all(&w.watchd).unwrap();
        let now = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let lines = format!(
            "{}\n{}\n",
            json!({"time": now - 8 * 86400, "type": "route", "iid": 1}),
            json!({"time": now, "type": "route", "iid": 2})
        );
        std::fs::write(w.watchd.join("events.jsonl"), lines).unwrap();
        w.env.write_engine_state("old", "{}");
        w.env.write_engine_state("new", "{}");
        let old = std::fs::File::options()
            .write(true)
            .open(w.env.engine_state("old"))
            .unwrap();
        old.set_modified(SystemTime::now() - Duration::from_secs(8 * 86400))
            .unwrap();
        w.events("app", &[ev("todo", 5)]);
        w.watch(&[]);
        let log = std::fs::read_to_string(w.watchd.join("events.jsonl")).unwrap();
        let routes: Vec<Value> = log
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .filter(|line| line["type"] == "route")
            .map(|line| line["iid"].clone())
            .collect();
        c.check("old log lines go away", "[2]", Value::from(routes).to_string());
        let gone = |key: &str| if w.env.engine_state(key).exists() { "no" } else { "yes" };
        c.check(
            "old engine state goes away",
            "yes no",
            format!("{} {}", gone("old"), gone("new")),
        );
        c
    })
}

fn event_lines(path: &std::path::Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

fn follow() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let follow = |after: u64, name: &str| {
            let mut command = w.command();
            command.args(["follow", "--after", &after.to_string()]);
            w.spawn_logged(command, name)
        };
        w.events("app", &[ev("todo", 5)]);
        w.watch(&[]);
        let first = w.log_last()["id"].as_u64().unwrap();
        let (follower, out) = follow(first, "follow.out");
        wait_for(5, || std::fs::metadata(&out).is_ok_and(|meta| meta.len() > 0));
        w.events("app", &[ev("note", 6)]);
        w.watch(&[]);
        wait_for(5, || {
            std::fs::read_to_string(&out).unwrap_or_default().contains(r#""note""#)
        });
        let lines = event_lines(&out);
        let event = lines
            .iter()
            .find(|line| line["type"] == "event")
            .cloned()
            .unwrap_or(Value::Null);
        c.check(
            "follow gets the sidebar state, then a new event with a greater id",
            r#"["sidebar","note",true]"#,
            json!([
                lines.first().map_or(Value::Null, |line| line["type"].clone()),
                event["event"]["kind"],
                event["id"].as_u64().is_some_and(|id| id > first)
            ])
            .to_string(),
        );
        let last = lines
            .iter()
            .filter(|line| line["type"] == "event")
            .last()
            .and_then(|line| line["id"].as_u64())
            .unwrap_or(0);
        end(follower);
        w.stop_daemon();
        w.events("app", &[ev("todo", 7)]);
        w.watch(&[]);
        let (follower, out) = follow(last, "follow2.out");
        wait_for(5, || {
            std::fs::read_to_string(&out).unwrap_or_default().contains(r#""todo""#)
        });
        sleep(1);
        end(follower);
        let events: Vec<Value> = event_lines(&out)
            .iter()
            .filter(|line| line["type"] == "event")
            .map(|line| {
                json!([
                    line["event"]["kind"],
                    line["event"]["iid"],
                    line["id"].as_u64().is_some_and(|id| id > last)
                ])
            })
            .collect();
        c.check(
            "follow --after the last id after a daemon restart: no line comes two times",
            r#"[["todo",7,true]]"#,
            Value::from(events).to_string(),
        );
        c
    })
}

fn follow_idle() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let mut command = w.command();
        command.arg("follow").env("WATCHD_IDLE_SECONDS", "2");
        let (follower, out) = w.spawn_logged(command, "follow.out");
        wait_for(5, || std::fs::metadata(&out).is_ok_and(|meta| meta.len() > 0));
        let pid = w.daemon_pid().unwrap_or(0);
        sleep(5);
        c.check(
            "a follow client keeps the daemon alive past the idle limit",
            "yes",
            if alive(pid) { "yes" } else { "no" },
        );
        end(follower);
        wait_for(8, || !alive(pid));
        c.check(
            "with no follow client, the daemon stops at the idle limit",
            "no",
            if alive(pid) { "yes" } else { "no" },
        );
        c
    })
}

fn replace_clients() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let client = w.start(w.watch_command(&[]));
        wait_for(10, || w.has_sub("app"));
        w.client(&["debug", "replace-clients", "--repo", w.env.repo.to_str().unwrap()]);
        c.check("replace-clients: the waiting client exits 3", "3", client.code());
        c
    })
}

#[test]
fn routed_event_log_line() {
    log_and_worktrees().assert("routed event: log line");
}

#[test]
fn reaction_sound_none() {
    log_and_worktrees().assert("reaction: sound none");
}

#[test]
fn a_new_record_has_no_herdr_workspace() {
    log_and_worktrees().assert("a new record has no herdr workspace");
}

#[test]
fn all_mrs_merged_worktree_stage_done() {
    log_and_worktrees().assert("all MRs merged: worktree stage done");
}

#[test]
fn unsubscribe_worktree_stage_stopped() {
    log_and_worktrees().assert("unsubscribe: worktree stage stopped");
}

#[test]
fn permanent_error_stopped_line() {
    log_and_worktrees().assert("permanent error: stopped line");
}

#[test]
fn permanent_error_of_a_stack_stopped_line_has_the_mr_title() {
    log_and_worktrees().assert("permanent error of a stack: stopped line has the MR title");
}

#[test]
fn kind_outside_a_git_repo_does_nothing() {
    log_and_worktrees().assert("kind outside a git repo does nothing");
}

#[test]
fn kind_writes_the_worktree_state() {
    log_and_worktrees().assert("kind: writes the worktree state");
}

#[test]
fn unknown_kind() {
    log_and_worktrees().assert("unknown kind");
}

#[test]
fn kind_during_a_live_watch_keeps_the_stage() {
    log_and_worktrees().assert("kind during a live watch keeps the stage");
}

#[test]
fn subscribe_with_no_kind_sets_the_kind_of_the_mode_stack() {
    log_and_worktrees().assert("subscribe with no kind sets the kind of the mode: stack");
}

#[test]
fn subscribe_with_no_kind_sets_the_kind_of_the_mode_review() {
    log_and_worktrees().assert("subscribe with no kind sets the kind of the mode: review");
}

#[test]
fn subscribe_with_no_kind_sets_the_kind_of_the_mode_hub() {
    log_and_worktrees().assert("subscribe with no kind sets the kind of the mode: hub");
}

#[test]
fn subscribe_keeps_an_existing_kind() {
    log_and_worktrees().assert("subscribe keeps an existing kind");
}

#[test]
fn route_log_line() {
    log_and_worktrees().assert("route: log line");
}

#[test]
fn route_unknown_action() {
    log_and_worktrees().assert("route: unknown action");
}

#[test]
fn no_herdr_call() {
    log_and_worktrees().assert("no herdr call");
}

#[test]
fn old_log_lines_go_away() {
    prune().assert("old log lines go away");
}

#[test]
fn old_engine_state_goes_away() {
    prune().assert("old engine state goes away");
}

#[test]
fn follow_gets_the_sidebar_state_then_a_new_event_with_a_greater_id() {
    follow().assert("follow gets the sidebar state, then a new event with a greater id");
}

#[test]
fn follow_after_the_last_id_after_a_daemon_restart_no_line_comes_two_times() {
    follow().assert("follow --after the last id after a daemon restart: no line comes two times");
}

#[test]
fn a_follow_client_keeps_the_daemon_alive_past_the_idle_limit() {
    follow_idle().assert("a follow client keeps the daemon alive past the idle limit");
}

#[test]
fn with_no_follow_client_the_daemon_stops_at_the_idle_limit() {
    follow_idle().assert("with no follow client, the daemon stops at the idle limit");
}

#[test]
fn replace_clients_the_waiting_client_exits_3() {
    replace_clients().assert("replace-clients: the waiting client exits 3");
}
