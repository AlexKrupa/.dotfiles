//! The router of the hub: a fixed rule for each event that needs no judgment. `decide` is pure, and
//! the side effects run after it.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::core::items::RoutedEvent;
use crate::engine::event::{Event, EventKind, FailedJob};
use crate::report::ReportInput;

pub mod execute;
pub mod retry;

#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    StartReview { iid: u64, title: String, branch: String, url: String },
    StartBump { iid: u64, title: String, branch: String, url: String },
    RetryJob { job: FailedJob, branch: String, pipeline: u64, url: String },
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

/// The review report of each MR of the events: the first `*-mr-<iid>-*.md` file of the folder.
pub fn read_facts(reviews: &Path, events: &[RoutedEvent]) -> Facts {
    let mut names: Vec<String> = std::fs::read_dir(reviews)
        .map(|entries| {
            entries
                .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
                .filter(|name| name.ends_with(".md"))
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    let mut reviewed = BTreeMap::new();
    for iid in events.iter().filter_map(|routed| routed.event.iid) {
        let part = format!("-mr-{iid}-");
        if let Some(name) = names.iter().find(|name| name.contains(&part)) {
            reviewed.insert(iid, reviews.join(name));
        }
    }
    Facts {
        reviewed,
        ..Facts::default()
    }
}

impl Routing {
    pub fn add(&mut self, other: Routing) {
        self.input.cells.extend(other.input.cells);
        self.input.agent.extend(other.input.agent);
        self.input.close.extend(other.input.close);
        self.input.add.extend(other.input.add);
        self.handled.extend(other.handled);
    }

    /// Takes the fields of the rows out of `self`, and all added rows.
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
                add: std::mem::take(&mut self.input.add),
            },
            handled,
        }
    }
}

pub fn decide(events: &[RoutedEvent], facts: &Facts) -> Vec<Decision> {
    let mut mrs: BTreeMap<u64, MrRound> = BTreeMap::new();
    for iid in events.iter().filter_map(|routed| routed.event.iid) {
        if !mrs.contains_key(&iid) {
            let of_mr: Vec<&RoutedEvent> = events.iter().filter(|routed| routed.event.iid == Some(iid)).collect();
            mrs.insert(iid, mr_round(&of_mr, facts));
        }
    }
    let no_mr = MrRound::default();
    events
        .iter()
        .flat_map(|routed| {
            let mr = routed.event.iid.and_then(|iid| mrs.get(&iid)).unwrap_or(&no_mr);
            actions_of(routed, mr, facts)
                .into_iter()
                .map(|action| Decision { row: routed.row, action })
        })
        .collect()
}

/// What all events of one MR in the round show: one agent at most for each MR.
#[derive(Default)]
struct MrRound {
    author: Option<String>,
    start: Option<Decision>,
}

/// A bot is an MR author whose username has `renovate` or `dependabot`. The branch name does not
/// count, because a branch rule also matches the MRs that change the bot configuration.
fn is_bot(author: &str) -> bool {
    let author = author.to_lowercase();
    author.contains("renovate") || author.contains("dependabot")
}

fn is_review_request(event: &Event) -> bool {
    event.kind == EventKind::Todo && event.detail == "review_requested"
}

/// A bump starts at the `opened` event, else at the first event of the MR. A review starts at the
/// review request.
fn mr_round(events: &[&RoutedEvent], facts: &Facts) -> MrRound {
    let author = events.iter().find_map(|routed| routed.event.author.clone());
    let start = match author.as_deref() {
        None => None,
        Some(author) if is_bot(author) => events
            .iter()
            .find(|routed| routed.event.kind == EventKind::Opened)
            .or(events.first())
            .map(|routed| start_of(routed, StartKind::Bump)),
        Some(_) => events
            .iter()
            .find(|routed| is_review_request(&routed.event))
            .filter(|routed| routed.event.iid.is_some_and(|iid| !facts.reviewed.contains_key(&iid)))
            .map(|routed| start_of(routed, StartKind::Review)),
    };
    MrRound { author, start }
}

enum StartKind {
    Review,
    Bump,
}

fn start_of(routed: &RoutedEvent, kind: StartKind) -> Decision {
    let event = &routed.event;
    let (iid, title, branch, url) = (
        event.iid.unwrap_or_default(),
        event.title.clone().unwrap_or_default(),
        event.branch.clone(),
        event.url.clone(),
    );
    let action = match kind {
        StartKind::Review => Action::StartReview { iid, title, branch, url },
        StartKind::Bump => Action::StartBump { iid, title, branch, url },
    };
    Decision { row: routed.row, action }
}

fn actions_of(routed: &RoutedEvent, mr: &MrRound, facts: &Facts) -> Vec<Action> {
    let action = match routed.event.kind {
        EventKind::Todo => todo_action(routed, mr, facts),
        EventKind::Opened => opened_action(routed, mr),
        EventKind::DefaultFailed => return default_failed_actions(&routed.event),
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
    };
    vec![action]
}

/// The start of the MR, if it is on this row.
fn start_on(routed: &RoutedEvent, mr: &MrRound) -> Option<Action> {
    mr.start
        .as_ref()
        .filter(|start| start.row == routed.row)
        .map(|start| start.action.clone())
}

fn todo_action(routed: &RoutedEvent, mr: &MrRound, facts: &Facts) -> Action {
    if let Some(start) = start_on(routed, mr) {
        return start;
    }
    if mr.author.is_none() {
        return Action::AskModel;
    }
    if mr.start.is_some() {
        return Action::Dismiss;
    }
    let reviewed = routed.event.iid.and_then(|iid| facts.reviewed.get(&iid));
    match reviewed.filter(|_| is_review_request(&routed.event)) {
        Some(path) => Action::ReportOnly {
            cell: Some(format!("Already reviewed: {}", path.display())),
        },
        None => Action::ReportOnly { cell: None },
    }
}

fn opened_action(routed: &RoutedEvent, mr: &MrRound) -> Action {
    if let Some(start) = start_on(routed, mr) {
        return start;
    }
    match mr.author {
        Some(_) => Action::Dismiss,
        None => Action::AskModel,
    }
}

const RUNNER_REASONS: [&str; 4] = [
    "runner_system_failure",
    "stuck_or_timeout_failure",
    "scheduler_failure",
    "api_failure",
];

fn is_runner_failure(job: &FailedJob) -> bool {
    job.failure_reason
        .as_deref()
        .is_some_and(|reason| RUNNER_REASONS.contains(&reason))
}

fn pipeline_id(event: &Event) -> Option<u64> {
    event.detail.strip_prefix("pipeline ")?.strip_suffix(" failed")?.parse().ok()
}

/// A retry for each job with a runner failure. The model gets the other jobs.
fn default_failed_actions(event: &Event) -> Vec<Action> {
    let (Some(failed), Some(pipeline)) = (event.failed.as_deref(), pipeline_id(event)) else {
        return vec![Action::AskModel];
    };
    let mut actions: Vec<Action> = failed
        .iter()
        .filter(|job| is_runner_failure(job))
        .map(|job| Action::RetryJob {
            job: job.clone(),
            branch: event.branch.clone(),
            pipeline,
            url: event.url.clone(),
        })
        .collect();
    if actions.is_empty() || !failed.iter().all(is_runner_failure) {
        actions.push(Action::AskModel);
    }
    actions
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

/// The event of the model has only the jobs that the daemon does not retry. A handled row keeps all
/// jobs for the board.
pub fn narrow(events: &mut [RoutedEvent], handled: &[u64]) {
    let to_model = |routed: &&mut RoutedEvent| {
        routed.event.kind == EventKind::DefaultFailed && !handled.contains(&routed.row)
    };
    for routed in events.iter_mut().filter(to_model) {
        let Some(failed) = routed.event.failed.as_mut() else {
            continue;
        };
        failed.retain(|job| !is_runner_failure(job));
        let names: Vec<String> = failed.iter().map(|job| job.name.clone()).collect();
        if let Some(jobs) = routed.event.jobs.as_mut() {
            jobs.retain(|name| names.contains(name));
        }
    }
}

/// The report fields of the decisions that need no side effect.
pub fn routing(decisions: &[Decision]) -> Routing {
    let mut routing = Routing::default();
    let mut asked = Vec::new();
    for decision in decisions {
        let row = decision.row;
        match &decision.action {
            Action::RetryJob { .. } => {
                if !routing.handled.contains(&row) {
                    routing.input.agent.push(row.into());
                    routing.handled.push(row);
                }
            }
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
            Action::AskModel => asked.push(row),
            Action::StartReview { .. } | Action::StartBump { .. } => {}
        }
    }
    // A row with a question for the model is not handled, also with a retry.
    routing.handled.retain(|row| !asked.contains(row));
    routing
        .input
        .agent
        .retain(|row| row.as_u64().is_none_or(|row| !asked.contains(&row)));
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

    fn mr_event(kind: EventKind, detail: &str, author: Option<&str>, row: u64) -> RoutedEvent {
        RoutedEvent {
            event: Event {
                author: author.map(str::to_string),
                ..Event::new(kind, Some(5), Some("Add foo"), "https://g/mr/5", "anna", detail, "ABC-1/foo")
            },
            row,
        }
    }

    fn actions(events: &[RoutedEvent], facts: &Facts) -> Vec<(u64, Action)> {
        decide(events, facts)
            .into_iter()
            .map(|decision| (decision.row, decision.action))
            .collect()
    }

    fn start_review() -> Action {
        Action::StartReview {
            iid: 5,
            title: "Add foo".to_string(),
            branch: "ABC-1/foo".to_string(),
            url: "https://g/mr/5".to_string(),
        }
    }

    fn start_bump() -> Action {
        Action::StartBump {
            iid: 5,
            title: "Add foo".to_string(),
            branch: "ABC-1/foo".to_string(),
            url: "https://g/mr/5".to_string(),
        }
    }

    #[test]
    fn review_request_of_a_reviewed_mr_is_report_only_with_the_report() {
        let facts = Facts {
            reviewed: BTreeMap::from([(5, PathBuf::from("/r/2026-10-01-mr-5-x.md"))]),
            ..Facts::default()
        };
        let events = [mr_event(EventKind::Todo, "review_requested", Some("bob"), 1)];

        assert_eq!(
            actions(&events, &facts),
            [(
                1,
                Action::ReportOnly {
                    cell: Some("Already reviewed: /r/2026-10-01-mr-5-x.md".to_string())
                }
            )]
        );
    }

    #[test]
    fn review_request_of_a_person_starts_a_review() {
        let events = [mr_event(EventKind::Todo, "review_requested", Some("bob"), 1)];

        assert_eq!(actions(&events, &Facts::default()), [(1, start_review())]);
    }

    #[test]
    fn opened_mr_of_a_bot_starts_a_bump() {
        let events = [mr_event(EventKind::Opened, "opened", Some("renovate-bot"), 1)];

        assert_eq!(actions(&events, &Facts::default()), [(1, start_bump())]);
    }

    #[test]
    fn todo_of_a_bot_mr_starts_a_bump() {
        let events = [mr_event(EventKind::Todo, "mentioned", Some("dependabot[bot]"), 1)];

        assert_eq!(actions(&events, &Facts::default()), [(1, start_bump())]);
    }

    #[test]
    fn opened_mr_of_a_person_is_dismissed() {
        let events = [mr_event(EventKind::Opened, "opened", Some("bob"), 1)];

        assert_eq!(actions(&events, &Facts::default()), [(1, Action::Dismiss)]);
    }

    #[test]
    fn other_todo_is_report_only() {
        let events = [mr_event(EventKind::Todo, "mentioned", Some("bob"), 1)];

        assert_eq!(actions(&events, &Facts::default()), [(1, Action::ReportOnly { cell: None })]);
    }

    #[test]
    fn mr_event_with_no_author_asks_the_model() {
        let events = [
            mr_event(EventKind::Todo, "review_requested", None, 1),
            mr_event(EventKind::Opened, "opened", None, 2),
        ];

        assert_eq!(
            actions(&events, &Facts::default()),
            [(1, Action::AskModel), (2, Action::AskModel)]
        );
    }

    #[test]
    fn bot_mr_with_review_request_starts_a_bump() {
        let events = [mr_event(EventKind::Todo, "review_requested", Some("renovate"), 1)];

        assert_eq!(actions(&events, &Facts::default()), [(1, start_bump())]);
    }

    #[test]
    fn opened_and_todo_of_one_mr_start_one_agent() {
        let review = [
            mr_event(EventKind::Opened, "opened", Some("bob"), 1),
            mr_event(EventKind::Todo, "review_requested", Some("bob"), 2),
        ];
        let bump = [
            mr_event(EventKind::Todo, "review_requested", None, 1),
            mr_event(EventKind::Opened, "opened", Some("renovate-bot"), 2),
        ];

        assert_eq!(
            actions(&review, &Facts::default()),
            [(1, Action::Dismiss), (2, start_review())]
        );
        assert_eq!(actions(&bump, &Facts::default()), [(1, Action::Dismiss), (2, start_bump())]);
    }

    #[test]
    fn read_facts_finds_the_first_review_report_of_each_mr() {
        let reviews = std::env::temp_dir().join(format!("watchd-router-{}-reviews", std::process::id()));
        let _ = std::fs::remove_dir_all(&reviews);
        std::fs::create_dir_all(&reviews).unwrap();
        for name in ["2026-10-02-mr-5-b.md", "2026-10-01-mr-5-a.md", "2026-10-01-mr-55-c.md", "x-mr-6-y.txt"] {
            std::fs::write(reviews.join(name), "").unwrap();
        }
        let events = [
            mr_event(EventKind::Todo, "review_requested", Some("bob"), 1),
            RoutedEvent {
                event: Event::new(EventKind::Opened, Some(6), None, "u", "bob", "opened", "b"),
                row: 2,
            },
        ];

        let facts = read_facts(&reviews, &events);

        assert_eq!(facts.reviewed, BTreeMap::from([(5, reviews.join("2026-10-01-mr-5-a.md"))]));
    }

    fn failed_job(id: u64, name: &str, reason: &str) -> FailedJob {
        FailedJob {
            id,
            name: name.to_string(),
            failure_reason: Some(reason.to_string()),
        }
    }

    fn default_failed(jobs: Vec<FailedJob>) -> RoutedEvent {
        RoutedEvent {
            event: Event {
                jobs: Some(jobs.iter().map(|job| job.name.clone()).collect()),
                failed: Some(jobs),
                item: Some("main-failed:main".to_string()),
                ..Event::new(
                    EventKind::DefaultFailed,
                    None,
                    None,
                    "https://g/-/pipelines/7",
                    "",
                    "pipeline 7 failed",
                    "main",
                )
            },
            row: 3,
        }
    }

    fn retry(job: FailedJob) -> Action {
        Action::RetryJob {
            job,
            branch: "main".to_string(),
            pipeline: 7,
            url: "https://g/-/pipelines/7".to_string(),
        }
    }

    #[test]
    fn default_failed_retries_runner_jobs_and_asks_for_the_rest() {
        let build = failed_job(11, "build", "runner_system_failure");
        let lint = failed_job(12, "lint", "script_failure");
        let test = failed_job(13, "test", "stuck_or_timeout_failure");
        let events = [default_failed(vec![build.clone(), lint.clone(), test.clone()])];

        let decisions = decide(&events, &Facts::default());

        let actions: Vec<(u64, Action)> = decisions.iter().map(|d| (d.row, d.action.clone())).collect();
        assert_eq!(actions, [(3, retry(build)), (3, retry(test)), (3, Action::AskModel)]);
        assert!(routing(&decisions).handled.is_empty());
        let mut model = events.to_vec();
        narrow(&mut model, &[]);
        assert_eq!(model[0].event.jobs, Some(vec!["lint".to_string()]));
        assert_eq!(model[0].event.failed, Some(vec![lint]));
    }

    #[test]
    fn default_failed_with_only_runner_jobs_is_an_agent_row() {
        let events = [default_failed(vec![failed_job(11, "build", "api_failure")])];

        let routing = routing(&decide(&events, &Facts::default()));

        assert_eq!(routing.handled, [3]);
        assert_eq!(routing.input.agent, [serde_json::json!(3)]);
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
