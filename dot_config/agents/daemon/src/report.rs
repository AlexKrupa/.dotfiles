//! The report of the last delivery of a subscription and of its open items, in the sections Needs
//! you, Agent, and Info.

use std::collections::BTreeMap;

use serde::Deserialize;

use crate::core::items::{Item, Items, Owner, RoutedEvent};
use crate::core::subs::Mode;
use crate::engine::event::{Event, EventKind};
use crate::platform::local_time;

/// The input of the model.
#[derive(Clone, Debug, Default, Deserialize, serde::Serialize)]
pub struct ReportInput {
    /// The Proposal or result text of a row, which an open item keeps for the next reports.
    #[serde(default)]
    pub cells: BTreeMap<String, serde_json::Value>,
    /// The rows of the Agent section, whose open items close.
    #[serde(default)]
    pub agent: Vec<serde_json::Value>,
    /// Open items to close, also items that the model added.
    #[serde(default)]
    pub close: Vec<serde_json::Value>,
    #[serde(default)]
    pub add: Vec<Add>,
}

#[derive(Clone, Debug, Deserialize, serde::Serialize)]
pub struct Add {
    pub section: AddSection,
    pub iid: Option<u64>,
    pub what: Option<String>,
    pub result: Option<String>,
}

/// A needs row opens an item, and an agent or info row is only in this report.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum AddSection {
    Needs,
    Agent,
    Info,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowSection {
    NeedsYou,
    Agent,
    Info,
}

impl RowSection {
    fn label(self) -> &'static str {
        match self {
            RowSection::NeedsYou => "Needs you",
            RowSection::Agent => "Agent",
            RowSection::Info => "Info",
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Known {
    pub title: Option<String>,
    pub url: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Row {
    pub n: u64,
    pub section: RowSection,
    pub iid: Option<u64>,
    pub title: Option<String>,
    pub url: Option<String>,
    pub event: Option<Event>,
    /// The text of a model row, else the sentence comes from the event.
    pub what: Option<String>,
    pub result: String,
    /// The time of an item from an earlier delivery.
    pub since: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct Link {
    pub title: Option<String>,
    pub iid: Option<u64>,
    pub url: String,
}

#[derive(Clone, Debug, Default)]
pub struct ReportData {
    pub known: BTreeMap<String, Known>,
    pub rows: Vec<Row>,
    pub links: Vec<Link>,
}

fn text_of(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

fn without_anchor(url: &str) -> String {
    url.split('#').next().unwrap_or_default().to_string()
}

pub fn build_report(
    input: &ReportInput,
    items: &Items,
    delivery: &[RoutedEvent],
    engine_titles: &BTreeMap<u64, String>,
    now: i64,
) -> (Items, ReportData) {
    let agent: Vec<String> = input.agent.iter().map(text_of).collect();
    let close: Vec<String> = input.close.iter().map(text_of).collect();
    let cell = |n: u64| input.cells.get(&n.to_string()).map(text_of);
    // Of the events of one row, a comment wins over its unaddressed line.
    let mut events: Vec<&RoutedEvent> = Vec::new();
    let mut by_row: Vec<&RoutedEvent> = delivery.iter().collect();
    by_row.sort_by_key(|event| (event.row, event.event.kind == EventKind::Unaddressed));
    for event in by_row {
        if events.last().is_none_or(|last| last.row != event.row) {
            events.push(event);
        }
    }
    // Each round with events repeats the unaddressed line of each open thread.
    let delivered: Vec<u64> = delivery
        .iter()
        .filter(|event| event.event.kind != EventKind::Unaddressed)
        .map(|event| event.row)
        .collect();
    let mut known: BTreeMap<String, Known> = BTreeMap::new();
    let sources = delivery
        .iter()
        .map(|event| (event.event.iid, event.event.title.clone(), Some(event.event.url.clone())))
        .chain(items.items.iter().map(|item| (item.iid, item.title.clone(), item.url.clone())));
    for (iid, title, url) in sources {
        let Some(iid) = iid else { continue };
        known.entry(iid.to_string()).or_insert(Known {
            title,
            url: Some(without_anchor(&url.unwrap_or_default())),
        });
    }
    // The engine state has the titles of the MRs with no event.
    for (iid, title) in engine_titles {
        known.entry(iid.to_string()).or_insert(Known { title: Some(title.clone()), url: None });
    }

    let mut updated = items.clone();
    for item in &mut updated.items {
        if let Some(text) = cell(item.n) {
            item.result = Some(text);
        }
    }
    let agent_items: Vec<Item> =
        updated.items.iter().filter(|item| agent.contains(&item.n.to_string())).cloned().collect();
    let mut state = updated.clone();
    state.items.retain(|item| {
        let n = item.n.to_string();
        !agent.contains(&n) && !close.contains(&n)
    });
    let mut new_items: Vec<u64> = Vec::new();
    let mut added_rows: Vec<Row> = Vec::new();
    for add in &input.add {
        let n = state.next;
        state.next += 1;
        let mr = add.iid.and_then(|iid| known.get(&iid.to_string())).cloned().unwrap_or_default();
        let result = add.result.clone().unwrap_or_default();
        let section = match add.section {
            AddSection::Needs => {
                state.items.push(Item {
                    n,
                    item: format!("model:{n}"),
                    owner: Owner::Model,
                    iid: add.iid,
                    title: mr.title,
                    url: mr.url,
                    what: add.what.clone(),
                    result: Some(result),
                    since: Some(now),
                    event: None,
                });
                new_items.push(n);
                continue;
            }
            AddSection::Agent => RowSection::Agent,
            AddSection::Info => RowSection::Info,
        };
        added_rows.push(Row {
            n,
            section,
            iid: add.iid,
            title: mr.title,
            url: mr.url,
            event: None,
            what: add.what.clone(),
            result,
            since: None,
        });
    }
    let open: Vec<String> = state.items.iter().map(|item| item.n.to_string()).collect();
    let item_row = |item: &Item, section: RowSection| Row {
        n: item.n,
        section,
        iid: item.iid,
        title: item.title.clone().or_else(|| item.event.as_ref().map(|event| event.branch.clone())),
        url: item.url.clone(),
        event: item.event.clone(),
        what: item.what.clone(),
        result: item.result.clone().unwrap_or_default(),
        since: match new_items.contains(&item.n) || delivered.contains(&item.n) {
            true => None,
            false => item.since,
        },
    };
    let event_row = |event: &RoutedEvent, section: RowSection| Row {
        n: event.row,
        section,
        iid: event.event.iid,
        title: event.event.title.clone().or_else(|| Some(event.event.branch.clone())),
        url: Some(event.event.url.clone()),
        event: Some(event.event.clone()),
        what: None,
        result: cell(event.row).unwrap_or_default(),
        since: None,
    };
    let mut sorted = state.items.clone();
    sorted.sort_by_key(|item| item.n);
    let mut rows: Vec<Row> = sorted.iter().map(|item| item_row(item, RowSection::NeedsYou)).collect();
    for id in &agent {
        let from_item = agent_items.iter().find(|item| &item.n.to_string() == id);
        let row = match from_item {
            Some(item) => Some(item_row(item, RowSection::Agent)),
            None => events
                .iter()
                .find(|event| &event.row.to_string() == id)
                .map(|event| event_row(event, RowSection::Agent)),
        };
        rows.extend(row);
    }
    rows.extend(added_rows.iter().filter(|row| row.section == RowSection::Agent).cloned());
    for event in &events {
        let row = event.row.to_string();
        if !open.contains(&row) && !agent.contains(&row) && !close.contains(&row) {
            rows.push(event_row(event, RowSection::Info));
        }
    }
    rows.extend(added_rows.iter().filter(|row| row.section == RowSection::Info).cloned());
    let mut links: Vec<(String, Link)> = Vec::new();
    for row in &rows {
        let Some(url) = row.url.as_ref().filter(|url| !url.is_empty()) else { continue };
        let key = match row.iid {
            Some(iid) => format!("!{iid}"),
            None => row.title.clone().unwrap_or_else(|| "null".to_string()),
        };
        if links.iter().all(|(known_key, _)| *known_key != key) {
            links.push((key, Link { title: row.title.clone(), iid: row.iid, url: without_anchor(url) }));
        }
    }
    let links = links.into_iter().map(|(_, link)| link).collect();
    (state, ReportData { known, rows, links })
}

fn capital(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

fn by(actor: &str, text: &str) -> String {
    match actor.is_empty() {
        true => capital(text),
        false => format!("@{actor} {text}"),
    }
}

fn line_of(event: &Event) -> String {
    let line = event.line.flatten().map_or("null".to_string(), |line| line.to_string());
    format!("{}:{line}", event.path.as_deref().unwrap_or_default())
}

pub fn sentence(event: &Event) -> String {
    let actor = event.actor.as_str();
    let detail = event.detail.as_str();
    match event.kind {
        EventKind::Todo => match detail {
            "review_requested" => by(actor, "requested your review"),
            "mentioned" | "directly_addressed" => by(actor, "mentioned you"),
            "approval_required" => by(actor, "requested your approval"),
            _ if actor.is_empty() => capital(&detail.replace('_', " ")),
            _ => format!("@{actor}: {}", detail.replace('_', " ")),
        },
        EventKind::Comment | EventKind::Unaddressed => match event.path {
            Some(_) => by(actor, &format!("on {}: \"{detail}\"", line_of(event))),
            None => format!("@{actor}: \"{detail}\""),
        },
        EventKind::OwnComment => match event.path {
            Some(_) => format!("Your comment on {}: \"{detail}\"", line_of(event)),
            None => format!("Your comment: \"{detail}\""),
        },
        EventKind::Note => by(actor, &format!("commented: \"{detail}\"")),
        EventKind::Reaction => by(actor, &format!("reacted {detail}")),
        EventKind::Opened => by(actor, "opened a dependency bump"),
        EventKind::DefaultFailed => failed(event),
        EventKind::Pipeline if event.jobs.is_some() => failed(event),
        EventKind::Pipeline => "Pipeline passed".to_string(),
        EventKind::Approved => by(actor, "approved"),
        EventKind::Unapproved => by(actor, "removed the approval"),
        EventKind::Conflict => "Merge conflict".to_string(),
        EventKind::Mergeable => "Ready to merge".to_string(),
        EventKind::Merged => "Merged".to_string(),
        EventKind::Closed => "Closed".to_string(),
        EventKind::Draft => by(actor, "marked it as draft"),
        EventKind::Ready => by(actor, "marked it as ready"),
        EventKind::Title => by(actor, "changed the title"),
        EventKind::Description => by(actor, "changed the description"),
        EventKind::Labels => by(actor, "changed the labels"),
        EventKind::Pushed => "New commits".to_string(),
        EventKind::Resolved => by(actor, "resolved your thread"),
    }
}

fn failed(event: &Event) -> String {
    match event.jobs.as_deref().unwrap_or_default() {
        [] => "Pipeline failed".to_string(),
        jobs => format!("Pipeline failed: {}", jobs.join(", ")),
    }
}

fn cell(text: &str) -> String {
    let mut one_line = String::new();
    let mut in_break = false;
    for char in text.chars() {
        match (char == '\r' || char == '\n', in_break) {
            (true, true) => {}
            (true, false) => one_line.push(' '),
            (false, _) => one_line.push(char),
        }
        in_break = char == '\r' || char == '\n';
    }
    let cut = match one_line.chars().count() > 200 {
        true => one_line.chars().take(197).collect::<String>() + "...",
        false => one_line,
    };
    cut.replace('|', "\\|")
}

fn what(row: &Row) -> String {
    let since = match row.since {
        Some(time) => {
            let (hour, minute, _) = local_time(time);
            format!("Since {hour:02}:{minute:02}: ")
        }
        None => String::new(),
    };
    let text = match (&row.what, &row.event) {
        (Some(what), _) => what.clone(),
        (None, Some(event)) => sentence(event),
        (None, None) => String::new(),
    };
    since + &text
}

fn pad(text: &str, width: usize) -> String {
    let length = text.chars().count();
    text.to_string() + &" ".repeat(width.saturating_sub(length))
}

fn table(header: &[&str], rows: &[Vec<String>]) -> Vec<String> {
    let all: Vec<Vec<String>> =
        std::iter::once(header.iter().map(|text| text.to_string()).collect()).chain(rows.iter().cloned()).collect();
    let widths: Vec<usize> = (0..header.len())
        .map(|column| all.iter().map(|row| row[column].chars().count()).max().unwrap_or(0).max(3))
        .collect();
    let line = |row: &Vec<String>| {
        let cells: Vec<String> = row.iter().zip(&widths).map(|(text, width)| pad(text, *width)).collect();
        format!("| {} |", cells.join(" | "))
    };
    let dashes: Vec<String> = widths.iter().map(|width| "-".repeat(*width)).collect();
    let mut lines = vec![line(&all[0]), format!("| {} |", dashes.join(" | "))];
    lines.extend(all[1..].iter().map(line));
    lines
}

fn title_text(title: &Option<String>) -> String {
    title.clone().unwrap_or_else(|| "null".to_string())
}

fn work_table(rows: &[&Row]) -> Vec<String> {
    let cells: Vec<Vec<String>> = rows
        .iter()
        .map(|row| vec![row.n.to_string(), row.section.label().to_string(), cell(&what(row)), cell(&row.result)])
        .collect();
    table(&["#", "Section", "What happened", "Proposal or result"], &cells)
}

pub fn render(mode: Mode, time: &str, mrs: &[u64], data: &ReportData) -> String {
    let mut lines = vec![time.to_string()];
    match mode {
        Mode::Hub => {
            if data.rows.is_empty() {
                return time.to_string();
            }
            let cells: Vec<Vec<String>> = data
                .rows
                .iter()
                .map(|row| {
                    vec![
                        row.n.to_string(),
                        row.section.label().to_string(),
                        cell(row.title.as_deref().unwrap_or_default()),
                        cell(&what(row)),
                        cell(&row.result),
                    ]
                })
                .collect();
            lines.push(String::new());
            lines.extend(table(&["#", "Section", "MR", "What happened", "Proposal or result"], &cells));
            lines.push(String::new());
            for link in &data.links {
                lines.push(match link.iid {
                    Some(iid) => format!("{} (!{iid}) {}", title_text(&link.title), link.url),
                    None => format!("{} {}", title_text(&link.title), link.url),
                });
            }
        }
        Mode::Stack | Mode::Review => {
            for iid in mrs {
                let mr_rows: Vec<&Row> = data.rows.iter().filter(|row| row.iid == Some(*iid)).collect();
                let mr = data.known.get(&iid.to_string()).cloned().unwrap_or_default();
                if mr_rows.is_empty() && mr.title.is_none() {
                    continue;
                }
                lines.push(String::new());
                let url = mr.url.filter(|url| !url.is_empty()).map(|url| format!(" {url}")).unwrap_or_default();
                lines.push(format!("{} (!{iid}){url}", title_text(&mr.title)));
                if !mr_rows.is_empty() {
                    lines.push(String::new());
                    lines.extend(work_table(&mr_rows));
                }
            }
            let other: Vec<&Row> =
                data.rows.iter().filter(|row| !row.iid.is_some_and(|iid| mrs.contains(&iid))).collect();
            if !other.is_empty() {
                lines.push(String::new());
                lines.extend(work_table(&other));
            }
        }
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::items::assign_rows;

    const MR_URL: &str = "https://gitlab.example.com/app/-/merge_requests";
    const PL_URL: &str = "https://gitlab.example.com/app/-/pipelines";

    fn input(json: &str) -> ReportInput {
        serde_json::from_str(json).unwrap()
    }

    fn mr_event(kind: EventKind, iid: u64, actor: &str, detail: &str, url: &str) -> Event {
        Event::new(kind, Some(iid), Some("Add foo"), url, actor, detail, "b")
    }

    #[test]
    fn report_hub_mode_is_one_table_with_mr_column() {
        let todo = Event {
            item: Some("todo:11".to_string()),
            ..mr_event(EventKind::Todo, 5, "anna", "review_requested", &format!("{MR_URL}/5"))
        };
        let failed = Event {
            previous: Some(Some("success".to_string())),
            item: Some("main-failed:develop".to_string()),
            jobs: Some(vec!["unit-tests".to_string()]),
            ..Event::new(EventKind::DefaultFailed, None, None, &format!("{PL_URL}/88123"), "", "pipeline 88123 failed", "develop")
        };
        let reaction = mr_event(EventKind::Reaction, 5, "bob", ":tada: on your comment", &format!("{MR_URL}/5#note_7"));
        let mut items = Items::default();
        let delivery = assign_rows(&mut items, vec![todo, failed, reaction], 100);
        let (items, data) = build_report(
            &input(r#"{"cells": {"2": "Retried, 1 of 2"}, "agent": ["2"]}"#),
            &items,
            &delivery,
            &BTreeMap::new(),
            200,
        );
        assert_eq!(
            render(Mode::Hub, "10:00", &[], &data),
            format!(
                "10:00

| #   | Section   | MR      | What happened                       | Proposal or result |
| --- | --------- | ------- | ----------------------------------- | ------------------ |
| 1   | Needs you | Add foo | @anna requested your review         |                    |
| 2   | Agent     | develop | Pipeline failed: unit-tests         | Retried, 1 of 2    |
| 3   | Info      | Add foo | @bob reacted :tada: on your comment |                    |

Add foo (!5) {MR_URL}/5
develop {PL_URL}/88123"
            )
        );
        let open: Vec<&str> = items.items.iter().map(|item| item.item.as_str()).collect();
        assert_eq!(open, vec!["todo:11"]);
    }

    #[test]
    fn report_stack_mode_is_one_table_for_each_mr_with_title_and_url() {
        let delivery = vec![RoutedEvent { event: mr_event(EventKind::Approved, 5, "anna", "approved", "u"), row: 1 }];
        let titles = BTreeMap::from([(5, "Add foo".to_string()), (6, "Add bar".to_string())]);
        let (_, data) = build_report(&input("{}"), &Items::default(), &delivery, &titles, 200);
        assert_eq!(
            render(Mode::Stack, "10:00", &[5, 6], &data),
            "10:00

Add foo (!5) u

| #   | Section | What happened  | Proposal or result |
| --- | ------- | -------------- | ------------------ |
| 1   | Info    | @anna approved |                    |

Add bar (!6)"
        );
    }

    #[test]
    fn report_add_needs_opens_a_model_item_with_a_new_number() {
        let items = Items { next: 4, items: Vec::new() };
        let add = r#"{"add": [{"section": "needs", "iid": 5, "what": "Fix waits", "result": "Ask the agent"}]}"#;
        let (items, data) = build_report(&input(add), &items, &[], &BTreeMap::new(), 200);
        assert_eq!(items.next, 5);
        let item = &items.items[0];
        assert_eq!((item.n, item.item.as_str(), item.owner), (4, "model:4", Owner::Model));
        assert_eq!((item.what.as_deref(), item.result.as_deref(), item.since), (Some("Fix waits"), Some("Ask the agent"), Some(200)));
        assert_eq!(data.rows[0].section, RowSection::NeedsYou);
        assert_eq!(data.rows[0].since, None);
    }

    #[test]
    fn report_repeats_unaddressed_lines_without_resetting_since() {
        let thread = Item {
            n: 1,
            item: "thread:d1".to_string(),
            owner: Owner::Daemon,
            iid: Some(5),
            title: Some("Add foo".to_string()),
            url: Some("u".to_string()),
            what: None,
            result: None,
            since: Some(100),
            event: Some(mr_event(EventKind::Comment, 5, "anna", "Why?", "u")),
        };
        let items = Items { next: 3, items: vec![thread] };
        let unaddressed = Event { item: Some("thread:d1".to_string()), ..mr_event(EventKind::Unaddressed, 5, "anna", "Why?", "u") };
        let delivery = vec![
            RoutedEvent { event: mr_event(EventKind::Approved, 5, "carl", "approved", "u"), row: 2 },
            RoutedEvent { event: unaddressed, row: 1 },
        ];
        let (items, data) = build_report(&input("{}"), &items, &delivery, &BTreeMap::new(), 200);
        assert_eq!(items.items[0].since, Some(100));
        assert_eq!((data.rows[0].n, data.rows[0].since), (1, Some(100)));
        assert_eq!(data.rows.len(), 2);
    }
}
