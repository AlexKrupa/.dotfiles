mod support;

use std::sync::OnceLock;

use serde_json::{Value, json};
use support::daemon::{Watchd, ev, norm, wait_for};
use support::{Checks, Run};

const MR_URL: &str = "https://gitlab.example.com/app/-/merge_requests";
const PL_URL: &str = "https://gitlab.example.com/app/-/pipelines";

fn rows(out: &str) -> String {
    out.lines()
        .map(|line| support::raw(&serde_json::from_str::<Value>(line).unwrap()["row"]))
        .collect::<Vec<_>>()
        .join(" ")
}

fn iev(kind: &str, iid: u64, item: &str) -> String {
    json!({"kind": kind, "iid": iid, "title": "Add foo", "url": "u", "actor": "anna", "detail": "d", "branch": "b",
        "item": item})
    .to_string()
}

fn item_fields(items: &Value, fields: &[&str]) -> String {
    let items = items["items"].as_array().cloned().unwrap_or_default();
    let rows: Vec<Value> = items
        .iter()
        .map(|item| fields.iter().map(|field| item[*field].clone()).collect())
        .collect();
    Value::from(rows).to_string()
}

fn item_keys(items: &Value) -> String {
    let items = items["items"].as_array().cloned().unwrap_or_default();
    Value::from(items.iter().map(|item| item["item"].clone()).collect::<Vec<_>>()).to_string()
}

fn gone(items: &Value) -> &'static str {
    if items.is_null() { "yes" } else { "no" }
}

fn write_items(w: &Watchd, key: &str, json: &str) {
    std::fs::create_dir_all(w.watchd.join("items")).unwrap();
    std::fs::write(w.watchd.join(format!("items/{key}.json")), format!("{json}\n")).unwrap();
}

fn body(out: &str) -> String {
    let lines: Vec<&str> = out.lines().collect();
    match lines.as_slice() {
        [time, "", rest @ ..] if is_time(time) => rest.join("\n"),
        _ => out.to_string(),
    }
}

fn is_time(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 5
        && matches!(bytes[0], b'0'..=b'2')
        && bytes[1].is_ascii_digit()
        && bytes[2] == b':'
        && matches!(bytes[3], b'0'..=b'5')
        && bytes[4].is_ascii_digit()
}

fn with_body(run: &Run) -> String {
    format!("{}\n{}", run.code, body(&run.out))
}

fn rows_of(out: &str, prefix: &str) -> Vec<String> {
    out.lines()
        .filter(|line| line.starts_with(prefix))
        .map(str::to_string)
        .collect()
}

fn hub_items() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.fake("app", "state", r#"{"present": ["todo:11"]}"#);
        w.events("app", &[iev("todo", 5, "todo:11")]);
        let out = w.watch_wait(&[]).out;
        c.check(
            "item event: row 1, items file has item 1",
            r#"1 [[1,"todo:11","daemon",5]]"#,
            format!(
                "{} {}",
                rows(&out),
                item_fields(&w.items_of("app"), &["n", "item", "owner", "iid"])
            ),
        );
        w.events("app", &[iev("todo", 5, "todo:11")]);
        c.check(
            "second event of the same item: same row",
            1,
            rows(&w.watch_wait(&[]).out),
        );
        w.events("app", &[ev("todo", 5)]);
        let out = w.watch_wait(&[]).out;
        c.check(
            "info event: new row, no item",
            "2 1",
            format!(
                "{} {}",
                rows(&out),
                w.items_of("app")["items"].as_array().map_or(0, Vec::len)
            ),
        );
        w.report(r#"{"add": [{"section": "needs", "iid": 5, "what": "w"}]}"#, &[]);
        w.fake("app", "state", r#"{"present": []}"#);
        w.events("app", &[ev("todo", 5)]);
        w.watch_wait(&[]);
        let items = || item_keys(&w.items_of("app"));
        wait_for(5, || items() == r#"["model:3"]"#);
        c.check(
            "not present: item removed",
            "no",
            if items().contains("todo") { "yes" } else { "no" },
        );
        c.check("model item: stays with no cause in GitLab", r#"["model:3"]"#, items());
        w.unsubscribe(&["--repo", w.env.repo.to_str().unwrap()]);
        c.check("unsubscribe of the hub: items stay", r#"["model:3"]"#, items());
        c
    })
}

fn review_moves() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let review = format!("{}-review-5", w.author_key());
        write_items(
            &w,
            "app",
            r#"{"next": 4, "items": [{"n": 3, "item": "todo:11", "owner": "daemon", "iid": 5},
            {"n": 2, "item": "todo:12", "owner": "daemon", "iid": 6}]}"#,
        );
        w.env
            .write_engine_state("app", r#"{"present": ["todo:11", "todo:12"]}"#);
        w.fake(&review, "state", r#"{"present": []}"#);
        w.events(&review, &[ev("comment", 5)]);
        w.watch_wait(&["--review", "--mr", "5"]);
        c.check(
            "live review: hub item moves",
            r#"[[1,"todo:11"]] [[2,"todo:12"]]"#,
            format!(
                "{} {}",
                item_fields(&w.items_of(&review), &["n", "item"]),
                item_fields(&w.items_of("app"), &["n", "item"])
            ),
        );
        w.events(&review, &[ev("merged", 5)]);
        w.watch_wait(&["--review", "--mr", "5"]);
        wait_for(5, || !w.has_sub(&review));
        c.check(
            "ended review: items go back to the hub",
            r#"[[2,"todo:12"],[4,"todo:11"]] yes"#,
            format!(
                "{} {}",
                item_fields(&w.items_of("app"), &["n", "item"]),
                gone(&w.items_of(&review))
            ),
        );
        c
    })
}

fn review_unsubscribe() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let review = format!("{}-review-5", w.author_key());
        write_items(
            &w,
            "app",
            r#"{"next": 2, "items": [{"n": 1, "item": "todo:11", "owner": "daemon", "iid": 5}]}"#,
        );
        w.events(&review, &[ev("comment", 5)]);
        w.watch_wait(&["--review", "--mr", "5"]);
        w.unsubscribe(&["--repo", w.env.repo.to_str().unwrap(), "--review", "--mr", "5"]);
        c.check(
            "unsubscribe of a review: items go back to the hub",
            r#"[[2,"todo:11"]] yes"#,
            format!(
                "{} {}",
                item_fields(&w.items_of("app"), &["n", "item"]),
                gone(&w.items_of(&review))
            ),
        );
        c
    })
}

fn author_rows() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let author = w.author_key();
        w.fake(&author, "state", r#"{"present": ["thread:d1"]}"#);
        w.events(
            &author,
            &[iev("comment", 5, "thread:d1"), iev("unaddressed", 5, "thread:d1")],
        );
        let first = rows(&w.watch_wait(&["--mr", "5"]).out);
        w.events(&author, &[ev("approved", 5), iev("unaddressed", 5, "thread:d1")]);
        let second = w.watch_wait(&["--mr", "5"]);
        c.check(
            "open item keeps its row in a second delivery",
            "1 1 | 2 1",
            format!("{first} | {}", rows(&second.out)),
        );
        w.unsubscribe(&["--repo", w.env.repo.to_str().unwrap(), "--mr", "5"]);
        c.check(
            "unsubscribe of an author watch: items go to the hub",
            r#"["thread:d1"] yes"#,
            format!("{} {}", item_keys(&w.items_of("app")), gone(&w.items_of(&author))),
        );
        c
    })
}

fn hub_report() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        w.fake("app", "state", r#"{"present": ["todo:11", "main-failed:develop"]}"#);
        w.events("app", &[
            json!({"kind": "todo", "iid": 5, "title": "Add foo", "url": format!("{MR_URL}/5"), "actor": "anna",
                "detail": "review_requested", "branch": "b", "item": "todo:11"}).to_string(),
            json!({"kind": "default-failed", "iid": null, "title": null, "url": format!("{PL_URL}/88123"), "actor": "",
                "detail": "pipeline 88123 failed", "branch": "develop", "previous": "success",
                "item": "main-failed:develop", "jobs": ["unit-tests"]}).to_string(),
            json!({"kind": "reaction", "iid": 5, "title": "Add foo", "url": format!("{MR_URL}/5#note_7"), "actor": "bob",
                "detail": ":tada: on your comment", "branch": "b"}).to_string(),
        ]);
        w.watch_wait(&[]);
        let run = w.report(r#"{"cells": {"2": "Retried, 1 of 2"}, "agent": ["2"]}"#, &[]);
        c.check("report: hub table", format!("0
| #   | Section   | MR      | What happened                       | Proposal or result |
| --- | --------- | ------- | ----------------------------------- | ------------------ |
| 1   | Needs you | Add foo | @anna requested your review         |                    |
| 2   | Agent     | develop | Pipeline failed: unit-tests         | Retried, 1 of 2    |
| 3   | Info      | Add foo | @bob reacted :tada: on your comment |                    |

- Add foo (!5) {MR_URL}/5
- develop {PL_URL}/88123"), with_body(&run));
        let items = || item_keys(&w.items_of("app"));
        c.check("report: agent closes the item", r#"["todo:11"]"#, items());
        w.report(r#"{"cells": {"1": "Review agent started"}}"#, &[]);
        let out = w.report("{}", &[]).out;
        c.check("report: cell of an open item stays",
            "| 1   | Needs you | Add foo | @anna requested your review         | Review agent started |",
            rows_of(&out, "| 1 ").join("\n"));
        let out = w.report(r#"{"cells": {"1": "a|b"}}"#, &[]).out;
        c.check("report: a pipe in a cell is escaped", r"a\|b", if out.contains(r"a\|b") { r"a\|b" } else { "" });
        let out = w.report(&format!(r#"{{"cells": {{"1": "{}"}}}}"#, "x".repeat(300)), &[]).out;
        let cell: String = rows_of(&out, "| 1 ")
            .iter()
            .filter_map(|row| row.split(" | ").nth(4).map(|cell| cell.replace([' ', '|'], "")))
            .collect();
        c.check("report: a long cell is cut at 200 characters", format!("{}...", "x".repeat(197)), cell);
        let out = w.report(r#"{"close": ["1"]}"#, &[]).out;
        c.check("report: close", "0 []", format!("{} {}", out.matches("Needs you").count(), w.items_of("app")["items"]));
        let out = w.report(r#"{"close": ["3"]}"#, &[]).out;
        c.check("report: close of a row with no open item hides it", "0 1",
            format!("{} {}", rows_of(&out, "| 3 ").len(), rows_of(&out, "| 1 ").len()));
        let out = w.report(r#"{"add": [{"section": "needs", "iid": 5, "what": "Fix waits, session not idle",
            "result": "Ask the agent"}]}"#, &[]).out;
        let model: Vec<Value> = w.items_of("app")["items"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .iter()
            .map(|item| json!({"item": item["item"], "owner": item["owner"], "what": item["what"], "result": item["result"]}))
            .collect();
        c.check("report: add needs opens a model item",
            norm(r#"[{"item":"model:4","owner":"model","what":"Fix waits, session not idle","result":"Ask the agent"}]"#),
            Value::from(model).to_string());
        let needs: Vec<String> = out
            .lines()
            .filter(|line| line.contains("Needs you"))
            .map(|line| {
                let line = line.split_whitespace().collect::<Vec<_>>().join(" ");
                let line = line.strip_suffix(" |").unwrap_or(&line).to_string();
                match line.strip_prefix("| ").and_then(|rest| rest.split_once(" | ")) {
                    Some((number, rest)) if number.bytes().all(|byte| byte.is_ascii_digit()) => rest.to_string(),
                    _ => line,
                }
            })
            .collect();
        c.check("report: the model item is a Needs you row", "Needs you | Add foo | Fix waits, session not idle | Ask the agent",
            needs.join("\n"));
        w.unsubscribe(&["--repo", w.env.repo.to_str().unwrap()]);
        c
    })
}

fn empty_report() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let run = w.report("{}", &[]);
        let only_time = run.out.lines().count() == 1 && is_time(&run.out);
        c.check(
            "report: no events, no items",
            "0 yes",
            format!("{} {}", run.code, if only_time { "yes" } else { "no" }),
        );
        c
    })
}

fn work_event(kind: &str, iid: u64, actor: &str, detail: &str, item: Option<&str>, at: Option<(&str, u64)>) -> Value {
    let title = if iid == 123 {
        "Fix crash on rotation"
    } else {
        "Fix rotation test"
    };
    let mut event = json!({"kind": kind, "iid": iid, "title": title, "url": format!("{MR_URL}/{iid}"), "actor": actor,
        "detail": detail, "branch": "b"});
    if let Some((path, line)) = at {
        event["path"] = json!(path);
        event["line"] = json!(line);
    }
    if let Some(item) = item {
        event["item"] = json!(item);
    }
    event
}

fn local_time(seconds: i64) -> String {
    let output = std::process::Command::new("date")
        .args(["-r", &seconds.to_string(), "+%H:%M"])
        .output()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn work_report() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let author = w.author_key();
        let mrs = ["--mr", "123", "--mr", "124"];
        w.fake(&author, "state", r#"{"present": ["thread:d1", "thread:d2", "pipeline:123"]}"#);
        w.events(&author, &[work_event("comment", 124, "bob", "Is this flow cold?", Some("thread:d2"), None).to_string()]);
        w.watch_wait(&mrs);
        w.report(r#"{"cells": {"1": "Yes. Answer: it starts on the first collect."}}"#, &mrs);
        let question = "Why not rememberSaveable here?";
        let mut pipeline = work_event("pipeline", 123, "", "pipeline 7 failed", Some("pipeline:123"), None);
        pipeline["jobs"] = json!(["ktlint"]);
        w.events(&author, &[
            work_event("comment", 123, "anna", question, Some("thread:d1"), Some(("NoteEditor.kt", 42))).to_string(),
            work_event("unaddressed", 123, "anna", question, Some("thread:d1"), Some(("NoteEditor.kt", 42))).to_string(),
            pipeline.to_string(),
            work_event("approved", 123, "carol", "approved", None, None).to_string(),
        ]);
        w.watch_wait(&mrs);
        let run = w.report(r#"{"cells": {"2": "Valid. Fix: replace the SavedStateHandle field",
            "3": "Formatted and pushed"}, "agent": ["3"]}"#, &mrs);
        let items = w.items_of(&author)["items"].as_array().cloned().unwrap_or_default();
        let since = items.iter().find(|item| item["n"] == 1).and_then(|item| item["since"].as_i64()).map_or(String::new(), local_time);
        c.check("report: work table, 2 MRs", format!("0
Fix crash on rotation (!123) {MR_URL}/123

| #   | Section   | What happened                                               | Proposal or result                             |
| --- | --------- | ----------------------------------------------------------- | ---------------------------------------------- |
| 2   | Needs you | @anna on NoteEditor.kt:42: \"Why not rememberSaveable here?\" | Valid. Fix: replace the SavedStateHandle field |
| 3   | Agent     | Pipeline failed: ktlint                                     | Formatted and pushed                           |
| 4   | Info      | @carol approved                                             |                                                |

Fix rotation test (!124) {MR_URL}/124

| #   | Section   | What happened                           | Proposal or result                           |
| --- | --------- | --------------------------------------- | -------------------------------------------- |
| 1   | Needs you | Since {since}: @bob: \"Is this flow cold?\" | Yes. Answer: it starts on the first collect. |"), with_body(&run));
        w.unsubscribe(&["--repo", w.env.repo.to_str().unwrap(), "--mr", "123", "--mr", "124"]);
        c
    })
}

fn mr_with_no_rows() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let author = w.author_key();
        w.fake(
            &author,
            "state",
            r#"{"mrs": {"5": {"title": "Add foo"}, "6": {"title": "Add bar"}}, "present": []}"#,
        );
        w.events(&author, &[ev("approved", 5)]);
        w.watch_wait(&["--mr", "5", "--mr", "6"]);
        let run = w.report("{}", &["--mr", "5", "--mr", "6"]);
        c.check(
            "report: MR with no rows has no table",
            "0
Add foo (!5) u

| #   | Section | What happened  | Proposal or result |
| --- | ------- | -------------- | ------------------ |
| 1   | Info    | @anna approved |                    |

Add bar (!6)",
            with_body(&run),
        );
        w.unsubscribe(&["--repo", w.env.repo.to_str().unwrap(), "--mr", "5", "--mr", "6"]);
        c
    })
}

fn hub_items_stay() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        write_items(
            &w,
            "app",
            r#"{"next": 2, "items": [{"n": 1, "item": "todo:11", "owner": "daemon", "iid": 5}]}"#,
        );
        w.events(&w.author_key(), &[ev("approved", 5)]);
        w.watch_wait(&["--mr", "5"]);
        w.local_rounds(2);
        c.check(
            "hub items with no hub record: no sweep log line, items stay",
            "0 yes",
            format!(
                "{} {}",
                w.log_count(" app results of an ended subscription removed"),
                if gone(&w.items_of("app")) == "no" { "yes" } else { "no" }
            ),
        );
        w.unsubscribe(&["--repo", w.env.repo.to_str().unwrap(), "--mr", "5"]);
        c
    })
}

fn old_thread_since() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        let author = w.author_key();
        w.fake(&author, "state", r#"{"present": ["thread:d1"]}"#);
        w.events(
            &author,
            &[iev("comment", 5, "thread:d1"), iev("unaddressed", 5, "thread:d1")],
        );
        w.watch_wait(&["--mr", "5"]);
        w.events(&author, &[ev("approved", 5), iev("unaddressed", 5, "thread:d1")]);
        w.watch_wait(&["--mr", "5"]);
        let out = w.report("{}", &["--mr", "5"]).out;
        let since = out
            .split("| Since ")
            .skip(1)
            .any(|rest| rest.len() > 13 && is_time(&rest[..5]) && rest[5..].starts_with(": @anna"));
        c.check(
            "report: an old thread in a new delivery has Since",
            "yes",
            if since { "yes" } else { "no" },
        );
        w.unsubscribe(&["--repo", w.env.repo.to_str().unwrap(), "--mr", "5"]);
        c
    })
}

fn items_not_json() -> &'static Checks {
    static CHECKS: OnceLock<Checks> = OnceLock::new();
    CHECKS.get_or_init(|| {
        let w = Watchd::new();
        let mut c = Checks::default();
        write_items(&w, "app", "not json");
        w.events("app", &[ev("todo", 5)]);
        let run = w.watch_wait(&[]);
        c.check(
            "items file not JSON: the events come, with a log line",
            format!("0 {} 1", ev("todo", 5)),
            format!(
                "{} {} {}",
                run.code,
                support::daemon::norow(&run.out),
                w.log_count("record removed")
            ),
        );
        w.unsubscribe(&["--repo", w.env.repo.to_str().unwrap()]);
        c
    })
}

#[test]
fn item_event_row_1_items_file_has_item_1() {
    hub_items().assert("item event: row 1, items file has item 1");
}

#[test]
fn second_event_of_the_same_item_same_row() {
    hub_items().assert("second event of the same item: same row");
}

#[test]
fn info_event_new_row_no_item() {
    hub_items().assert("info event: new row, no item");
}

#[test]
fn not_present_item_removed() {
    hub_items().assert("not present: item removed");
}

#[test]
fn model_item_stays_with_no_cause_in_gitlab() {
    hub_items().assert("model item: stays with no cause in GitLab");
}

#[test]
fn unsubscribe_of_the_hub_items_stay() {
    hub_items().assert("unsubscribe of the hub: items stay");
}

#[test]
fn live_review_hub_item_moves() {
    review_moves().assert("live review: hub item moves");
}

#[test]
fn ended_review_items_go_back_to_the_hub() {
    review_moves().assert("ended review: items go back to the hub");
}

#[test]
fn unsubscribe_of_a_review_items_go_back_to_the_hub() {
    review_unsubscribe().assert("unsubscribe of a review: items go back to the hub");
}

#[test]
fn open_item_keeps_its_row_in_a_second_delivery() {
    author_rows().assert("open item keeps its row in a second delivery");
}

#[test]
fn unsubscribe_of_an_author_watch_items_go_to_the_hub() {
    author_rows().assert("unsubscribe of an author watch: items go to the hub");
}

#[test]
fn report_hub_table() {
    hub_report().assert("report: hub table");
}

#[test]
fn report_agent_closes_the_item() {
    hub_report().assert("report: agent closes the item");
}

#[test]
fn report_cell_of_an_open_item_stays() {
    hub_report().assert("report: cell of an open item stays");
}

#[test]
fn report_a_pipe_in_a_cell_is_escaped() {
    hub_report().assert("report: a pipe in a cell is escaped");
}

#[test]
fn report_a_long_cell_is_cut_at_200_characters() {
    hub_report().assert("report: a long cell is cut at 200 characters");
}

#[test]
fn report_close() {
    hub_report().assert("report: close");
}

#[test]
fn report_close_of_a_row_with_no_open_item_hides_it() {
    hub_report().assert("report: close of a row with no open item hides it");
}

#[test]
fn report_add_needs_opens_a_model_item() {
    hub_report().assert("report: add needs opens a model item");
}

#[test]
fn report_the_model_item_is_a_needs_you_row() {
    hub_report().assert("report: the model item is a Needs you row");
}

#[test]
fn report_no_events_no_items() {
    empty_report().assert("report: no events, no items");
}

#[test]
fn report_work_table_2_mrs() {
    work_report().assert("report: work table, 2 MRs");
}

#[test]
fn report_mr_with_no_rows_has_no_table() {
    mr_with_no_rows().assert("report: MR with no rows has no table");
}

#[test]
fn hub_items_with_no_hub_record_no_sweep_log_line_items_stay() {
    hub_items_stay().assert("hub items with no hub record: no sweep log line, items stay");
}

#[test]
fn report_an_old_thread_in_a_new_delivery_has_since() {
    old_thread_since().assert("report: an old thread in a new delivery has Since");
}

#[test]
fn items_file_not_json_the_events_come_with_a_log_line() {
    items_not_json().assert("items file not JSON: the events come, with a log line");
}
