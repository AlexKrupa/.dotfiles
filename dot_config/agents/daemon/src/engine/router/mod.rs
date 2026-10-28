//! The router of the hub: a fixed rule for each event that needs no judgment. `decide` is pure, and
//! the side effects run after it.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::core::items::RoutedEvent;
use crate::engine::event::{Event, EventKind};
use crate::report::ReportInput;

#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    StartReview { iid: u64, title: String, branch: String, url: String },
    StartBump { iid: u64, title: String, branch: String, url: String },
    ReportOnly { cell: Option<String> },
    Dismiss,
    AskModel,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Decision {
    pub row: u64,
    pub action: Action,
}

/// The data that `decide` reads besides the events.
#[derive(Clone, Debug, Default)]
pub struct Facts {
    /// The review report of each MR that has one.
    pub reviewed: BTreeMap<u64, PathBuf>,
    /// The events are items of an own worktree with no agent.
    pub worktree: bool,
}

/// The report fields of the handled rows. The other rows go to the model.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Routing {
    pub input: ReportInput,
    pub handled: Vec<u64>,
}

impl Routing {
    pub fn add(&mut self, other: Routing) {
        self.input.cells.extend(other.input.cells);
        self.input.agent.extend(other.input.agent);
        self.input.close.extend(other.input.close);
        self.handled.extend(other.handled);
    }

    /// Takes the fields of the rows out of `self`.
    pub fn take(&mut self, rows: &[u64]) -> Routing {
        let of_rows = |value: &serde_json::Value| value.as_u64().is_some_and(|row| rows.contains(&row));
        let (cells, kept) = std::mem::take(&mut self.input.cells)
            .into_iter()
            .partition(|(row, _)| row.parse().is_ok_and(|row| rows.contains(&row)));
        self.input.cells = kept;
        let (agent, kept) = std::mem::take(&mut self.input.agent).into_iter().partition(of_rows);
        self.input.agent = kept;
        let (close, kept) = std::mem::take(&mut self.input.close).into_iter().partition(of_rows);
        self.input.close = kept;
        let (handled, kept) = std::mem::take(&mut self.handled)
            .into_iter()
            .partition(|row| rows.contains(row));
        self.handled = kept;
        Routing {
            input: ReportInput {
                cells,
                agent,
                close,
                add: Vec::new(),
            },
            handled,
        }
    }
}

pub fn decide(events: &[RoutedEvent], facts: &Facts) -> Vec<Decision> {
    events
        .iter()
        .map(|routed| Decision {
            row: routed.row,
            action: action_of(&routed.event, facts),
        })
        .collect()
}

fn action_of(event: &Event, facts: &Facts) -> Action {
    match event.kind {
        EventKind::Todo => todo_action(),
        EventKind::Opened => opened_action(),
        EventKind::DefaultFailed => default_failed_action(),
        EventKind::PullBlocked => pull_blocked_action(),
        EventKind::Note => note_action(),
        EventKind::Reaction => reaction_action(),
        EventKind::Pipeline
        | EventKind::Comment
        | EventKind::OwnComment
        | EventKind::Approved
        | EventKind::Unapproved
        | EventKind::Draft
        | EventKind::Ready
        | EventKind::Title
        | EventKind::Description
        | EventKind::Labels
        | EventKind::Conflict
        | EventKind::Mergeable
        | EventKind::Merged
        | EventKind::Closed
        | EventKind::Unaddressed
        | EventKind::Pushed
        | EventKind::Resolved => worktree_item_action(facts),
    }
}

fn todo_action() -> Action {
    Action::AskModel
}

fn opened_action() -> Action {
    Action::AskModel
}

fn default_failed_action() -> Action {
    Action::AskModel
}

fn pull_blocked_action() -> Action {
    Action::ReportOnly { cell: None }
}

fn note_action() -> Action {
    Action::ReportOnly { cell: None }
}

fn reaction_action() -> Action {
    Action::ReportOnly { cell: None }
}

/// The hub check gives none of these kinds. They come to the hub as items of an own worktree.
fn worktree_item_action(facts: &Facts) -> Action {
    match facts.worktree {
        true => Action::ReportOnly { cell: None },
        false => Action::AskModel,
    }
}

/// The report fields of the decisions that need no side effect.
pub fn routing(decisions: &[Decision]) -> Routing {
    let mut routing = Routing::default();
    for decision in decisions {
        let row = decision.row;
        match &decision.action {
            Action::ReportOnly { cell } => {
                if let Some(cell) = cell {
                    routing.input.cells.insert(row.to_string(), cell.clone().into());
                }
                routing.handled.push(row);
            }
            Action::Dismiss => {
                routing.input.close.push(row.into());
                routing.handled.push(row);
            }
            Action::StartReview { .. } | Action::StartBump { .. } | Action::AskModel => {}
        }
    }
    routing
}

#[cfg(test)]
mod tests {
    use super::*;

    fn routed(kind: EventKind, row: u64) -> RoutedEvent {
        RoutedEvent {
            event: Event::new(kind, Some(5), Some("Add foo"), "u", "anna", "d", "foo"),
            row,
        }
    }

    fn action_of(event: RoutedEvent) -> Vec<Action> {
        decide(&[event], &Facts::default())
            .into_iter()
            .map(|decision| decision.action)
            .collect()
    }

    #[test]
    fn pull_blocked_is_report_only() {
        assert_eq!(action_of(routed(EventKind::PullBlocked, 1)), [Action::ReportOnly { cell: None }]);
    }

    #[test]
    fn note_and_reaction_are_report_only() {
        assert_eq!(action_of(routed(EventKind::Note, 1)), [Action::ReportOnly { cell: None }]);
        assert_eq!(action_of(routed(EventKind::Reaction, 1)), [Action::ReportOnly { cell: None }]);
    }

    #[test]
    fn default_failed_asks_the_model() {
        assert_eq!(action_of(routed(EventKind::DefaultFailed, 1)), [Action::AskModel]);
    }

    #[test]
    fn todo_asks_the_model() {
        assert_eq!(action_of(routed(EventKind::Todo, 1)), [Action::AskModel]);
    }
}
