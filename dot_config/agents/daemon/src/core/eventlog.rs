use serde::{Deserialize, Serialize};

use crate::core::items::RoutedEvent;
use crate::core::subs::Mode;
use crate::engine::event::EventKind;

/// The line types of the event log `events.jsonl`, which `follow` sends to its readers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum LineType {
    Event,
    Stopped,
    Route,
}

/// `request`: the event asks for the user, and the plugin plays a sound.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Sound {
    Request,
    None,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RouteAction {
    Bump,
    Review,
    None,
}

impl RouteAction {
    pub fn parse(text: &str) -> Option<RouteAction> {
        match text {
            "bump" => Some(RouteAction::Bump),
            "review" => Some(RouteAction::Review),
            "none" => Some(RouteAction::None),
            _ => Option::None,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct EventLine {
    /// Increases from line to line, also across daemon restarts, so that a reader can go on after it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    pub time: i64,
    pub round: String,
    #[serde(rename = "type")]
    pub line_type: LineType,
    pub slug: String,
    pub key: String,
    pub mode: Mode,
    pub event: RoutedEvent,
    pub sound: Sound,
}

#[derive(Clone, Debug, Serialize)]
pub struct StoppedLine {
    /// Increases from line to line, also across daemon restarts, so that a reader can go on after it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    pub time: i64,
    #[serde(rename = "type")]
    pub line_type: LineType,
    pub slug: String,
    pub key: String,
    pub mode: Mode,
    /// The title of the first MR, `None` in hub mode.
    pub title: Option<String>,
    /// The first line of the error text.
    pub error: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct RouteLine {
    /// Increases from line to line, also across daemon restarts, so that a reader can go on after it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    pub time: i64,
    #[serde(rename = "type")]
    pub line_type: LineType,
    pub slug: String,
    pub key: String,
    pub iid: u64,
    pub action: RouteAction,
}

#[derive(Clone, Debug, Serialize)]
#[serde(untagged)]
pub enum LogLine {
    Event(EventLine),
    Stopped(StoppedLine),
    Route(RouteLine),
}

impl LogLine {
    pub fn set_id(&mut self, id: u64) {
        match self {
            LogLine::Event(line) => line.id = Some(id),
            LogLine::Stopped(line) => line.id = Some(id),
            LogLine::Route(line) => line.id = Some(id),
        }
    }
}

#[derive(Deserialize)]
struct WithId {
    id: Option<u64>,
}

pub fn id_of(line: &str) -> u64 {
    serde_json::from_str::<WithId>(line).ok().and_then(|line| line.id).unwrap_or(0)
}

/// At least the time in milliseconds, so that the ids increase also after the prune of the log.
pub fn next_id(last: u64, now_millis: u64) -> u64 {
    (last + 1).max(now_millis)
}

pub fn sound(routed: &RoutedEvent) -> Sound {
    let event = &routed.event;
    match event.kind {
        EventKind::Todo
        | EventKind::Note
        | EventKind::DefaultFailed
        | EventKind::Comment
        | EventKind::Conflict => Sound::Request,
        EventKind::Pipeline if event.jobs.is_some() => Sound::Request,
        EventKind::Pipeline
        | EventKind::Opened
        | EventKind::Reaction
        | EventKind::OwnComment
        | EventKind::Approved
        | EventKind::Unapproved
        | EventKind::Draft
        | EventKind::Ready
        | EventKind::Title
        | EventKind::Description
        | EventKind::Labels
        | EventKind::Mergeable
        | EventKind::Merged
        | EventKind::Closed
        | EventKind::Unaddressed
        | EventKind::Pushed
        | EventKind::Resolved => Sound::None,
    }
}

pub fn event_line(slug: &str, key: &str, mode: Mode, now: i64, event: RoutedEvent) -> EventLine {
    EventLine {
        id: None,
        time: now,
        round: format!("{key}-{now}"),
        line_type: LineType::Event,
        slug: slug.to_string(),
        key: key.to_string(),
        mode,
        sound: sound(&event),
        event,
    }
}

pub fn stopped_line(
    slug: &str,
    key: &str,
    mode: Mode,
    now: i64,
    title: Option<String>,
    error: &str,
) -> StoppedLine {
    StoppedLine {
        id: None,
        time: now,
        line_type: LineType::Stopped,
        slug: slug.to_string(),
        key: key.to_string(),
        mode,
        title,
        error: error.to_string(),
    }
}

pub fn route_line(now: i64, key: &str, iid: u64, action: RouteAction) -> RouteLine {
    RouteLine {
        id: None,
        time: now,
        line_type: LineType::Route,
        slug: key.to_string(),
        key: key.to_string(),
        iid,
        action,
    }
}

#[derive(Deserialize)]
struct Timed {
    time: i64,
}

pub fn prune_lines(lines: &str, cut: i64) -> String {
    lines
        .lines()
        .filter(|line| serde_json::from_str::<Timed>(line).map_or(true, |timed| timed.time >= cut))
        .map(|line| format!("{line}\n"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::event::Event;

    fn routed(kind: EventKind, jobs: Option<Vec<String>>) -> RoutedEvent {
        RoutedEvent { event: Event { jobs, ..Event::new(kind, Some(5), Some("T"), "u", "", "d", "b") }, row: 1 }
    }

    #[test]
    fn sound_is_request_for_failed_pipeline_with_jobs_only() {
        assert_eq!(sound(&routed(EventKind::Pipeline, Some(vec![]))), Sound::Request);
        assert_eq!(sound(&routed(EventKind::Pipeline, None)), Sound::None);
        assert_eq!(sound(&routed(EventKind::Todo, None)), Sound::Request);
        assert_eq!(sound(&routed(EventKind::Approved, None)), Sound::None);
    }

    #[test]
    fn event_line_has_the_fields_of_the_bash_daemon() {
        let line = event_line("app", "app", Mode::Hub, 100, routed(EventKind::Approved, None));
        assert_eq!(
            serde_json::to_string(&line).unwrap(),
            r#"{"time":100,"round":"app-100","type":"event","slug":"app","key":"app","mode":"hub","event":{"kind":"approved","iid":5,"title":"T","url":"u","actor":"","detail":"d","branch":"b","row":1},"sound":"none"}"#
        );
    }

    #[test]
    fn ids_increase_also_when_the_clock_is_behind() {
        assert_eq!(next_id(0, 1_000), 1_000);
        assert_eq!(next_id(1_000, 900), 1_001);
        let mut line = LogLine::Route(route_line(5, "app", 61, RouteAction::Bump));
        line.set_id(7);
        let text = serde_json::to_string(&line).unwrap();
        assert_eq!(text, r#"{"id":7,"time":5,"type":"route","slug":"app","key":"app","iid":61,"action":"bump"}"#);
        assert_eq!(id_of(&text), 7);
    }

    #[test]
    fn prune_lines_keeps_the_lines_of_the_last_7_days() {
        let lines = "{\"time\":5,\"type\":\"route\"}\n{\"time\":10,\"type\":\"route\"}\n";
        assert_eq!(prune_lines(lines, 10), "{\"time\":10,\"type\":\"route\"}\n");
    }
}
