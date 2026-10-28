//! The side effects of the router actions: the agent starts and the router result lines.

use std::path::Path;

use super::{Action, Decision, Routing, routing};
use crate::core::eventlog::{LogLine, RouteAction, route_line};
use crate::core::items::RoutedEvent;
use crate::daemon::store::Store;
use crate::engine::Engine;
use crate::engine::event::EventKind;
use crate::platform::now_seconds;
use crate::workspaces::{AgentStart, StartError, Workspaces};

pub struct ExecuteContext<'a> {
    /// The folder of the target, for the hub the main checkout.
    pub repo: &'a Path,
    /// The hub key.
    pub key: &'a str,
    pub workspaces: &'a dyn Workspaces,
    pub engine: &'a dyn Engine,
    pub store: &'a Store,
}

/// Runs the actions of the decisions. Each agent start and each dismissed new MR writes the router
/// result line, which the herdr `watch` plugin reads for its notification.
pub async fn execute(decisions: Vec<Decision>, events: &[RoutedEvent], ctx: &ExecuteContext<'_>) -> Routing {
    let mut routing = routing(&decisions);
    let started: Vec<u64> = decisions
        .iter()
        .filter_map(|decision| match &decision.action {
            Action::StartReview { iid, .. } | Action::StartBump { iid, .. } => Some(*iid),
            Action::ReportOnly { .. } | Action::Dismiss | Action::AskModel => None,
        })
        .collect();
    let now = now_seconds();
    let mut lines = Vec::new();
    for decision in decisions {
        let row = decision.row;
        match decision.action {
            Action::StartReview { iid, title, branch, url } => {
                lines.push(LogLine::Route(route_line(now, ctx.key, iid, RouteAction::Review)));
                let start = AgentStart {
                    title,
                    branch,
                    prompt: format!("/review-pr {url}"),
                };
                start_agent(ctx, &mut routing, row, &start, "Review agent started");
            }
            Action::StartBump { iid, title, branch, url } => {
                lines.push(LogLine::Route(route_line(now, ctx.key, iid, RouteAction::Bump)));
                let start = AgentStart {
                    title,
                    branch,
                    prompt: format!("/bump {url}"),
                };
                start_agent(ctx, &mut routing, row, &start, "Bump agent started");
            }
            Action::Dismiss => {
                let opened = events
                    .iter()
                    .find(|routed| routed.row == row && routed.event.kind == EventKind::Opened)
                    .and_then(|routed| routed.event.iid)
                    .filter(|iid| !started.contains(iid));
                if let Some(iid) = opened {
                    lines.push(LogLine::Route(route_line(now, ctx.key, iid, RouteAction::None)));
                }
            }
            Action::ReportOnly { .. } | Action::AskModel => {}
        }
    }
    ctx.store.event_log(lines);
    routing
}

/// A failed start keeps the row as a pending item, with the error text as its cell.
fn start_agent(ctx: &ExecuteContext<'_>, routing: &mut Routing, row: u64, start: &AgentStart, started: &str) {
    let result = tokio::task::block_in_place(|| ctx.workspaces.start_agent(ctx.repo, start));
    let cell = match result {
        Ok(()) => {
            routing.input.agent.push(row.into());
            started.to_string()
        }
        Err(StartError::Busy) => {
            routing.input.agent.push(row.into());
            "An agent works on the branch".to_string()
        }
        Err(StartError::Failed(text)) => text,
    };
    routing.input.cells.insert(row.to_string(), cell.into());
    routing.handled.push(row);
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use serde_json::json;

    use super::*;
    use crate::engine::event::Event;
    use crate::engine::fake::FakeEngine;
    use crate::paths::StateDirs;
    use crate::workspaces::FakeWorkspaces;

    struct Setup {
        base: PathBuf,
        store: Store,
        workspaces: FakeWorkspaces,
        engine: FakeEngine,
    }

    impl Setup {
        /// `start` is the result of each agent start: `ok`, `busy`, or an error text.
        fn new(name: &str, start: &str) -> Setup {
            let base = std::env::temp_dir().join(format!("watchd-execute-{}-{name}", std::process::id()));
            let _ = std::fs::remove_dir_all(&base);
            let store = Store::new(StateDirs {
                watchd: base.join("watchd"),
                engine: base.join("watch-gitlab"),
            });
            store.ensure_dirs().unwrap();
            let fake = base.join("fake");
            std::fs::create_dir_all(&fake).unwrap();
            std::fs::write(fake.join("start"), start).unwrap();
            Setup {
                workspaces: FakeWorkspaces { dir: fake.clone() },
                engine: FakeEngine {
                    dir: fake,
                    engine_dir: base.join("watch-gitlab"),
                },
                store,
                base,
            }
        }

        fn context(&self) -> ExecuteContext<'_> {
            ExecuteContext {
                repo: &self.base,
                key: "app",
                workspaces: &self.workspaces,
                engine: &self.engine,
                store: &self.store,
            }
        }

        fn calls(&self) -> String {
            std::fs::read_to_string(self.base.join("fake/calls")).unwrap_or_default()
        }

        fn route_actions(&self) -> Vec<String> {
            let text = std::fs::read_to_string(self.store.dirs.events()).unwrap_or_default();
            text.lines()
                .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
                .filter(|line| line["type"] == "route")
                .map(|line| format!("{} {}", line["iid"], line["action"].as_str().unwrap_or_default()))
                .collect()
        }
    }

    fn start_review(row: u64) -> Decision {
        Decision {
            row,
            action: Action::StartReview {
                iid: 5,
                title: "Add foo".to_string(),
                branch: "ABC-1/foo".to_string(),
                url: "https://g/mr/5".to_string(),
            },
        }
    }

    fn opened(row: u64, iid: u64) -> RoutedEvent {
        RoutedEvent {
            event: Event::new(EventKind::Opened, Some(iid), Some("T"), "u", "bob", "opened", "b"),
            row,
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn started_agent_is_an_agent_row() {
        let setup = Setup::new("ok", "ok");

        let routing = execute(vec![start_review(3)], &[], &setup.context()).await;

        assert_eq!(routing.handled, [3]);
        assert_eq!(routing.input.cells["3"], "Review agent started");
        assert_eq!(routing.input.agent, [json!(3)]);
        assert_eq!(setup.calls(), "start_agent ABC-1/foo /review-pr https://g/mr/5\n");
        assert_eq!(setup.route_actions(), ["5 review"]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn busy_branch_is_an_agent_row() {
        let setup = Setup::new("busy", "busy");

        let routing = execute(vec![start_review(3)], &[], &setup.context()).await;

        assert_eq!(routing.handled, [3]);
        assert_eq!(routing.input.cells["3"], "An agent works on the branch");
        assert_eq!(routing.input.agent, [json!(3)]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn failed_start_gives_its_text_and_keeps_the_item() {
        let setup = Setup::new("failed", "work-start: not a git repo: /x");

        let routing = execute(vec![start_review(3)], &[], &setup.context()).await;

        assert_eq!(routing.handled, [3]);
        assert_eq!(routing.input.cells["3"], "work-start: not a git repo: /x");
        assert!(routing.input.agent.is_empty());
        assert!(routing.input.close.is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn dismissed_opened_mr_with_no_start_writes_the_none_line() {
        let setup = Setup::new("dismissed", "ok");
        let decisions = vec![
            Decision {
                row: 1,
                action: Action::Dismiss,
            },
            Decision {
                row: 2,
                action: Action::Dismiss,
            },
            start_review(3),
        ];

        let routing = execute(decisions, &[opened(1, 6), opened(2, 5)], &setup.context()).await;

        assert_eq!(routing.input.close, [json!(1), json!(2)]);
        assert_eq!(setup.route_actions(), ["6 none", "5 review"]);
    }
}
