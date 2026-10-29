//! The side effects of the router actions: the agent starts and the router result lines.

use std::path::Path;

use super::retry::Retry;
use super::{Action, Decision, Routing, routing};
use crate::core::eventlog::{LogLine, RouteAction, route_line};
use crate::core::items::RoutedEvent;
use crate::daemon::store::Store;
use crate::engine::event::EventKind;
use crate::platform::now_seconds;
use crate::report::{Add, AddSection};
use crate::workspaces::{AgentStart, StartError, Workspaces};

pub struct ExecuteContext<'a> {
    /// The folder of the target, for the hub the main checkout.
    pub repo: &'a Path,
    /// The hub key.
    pub key: &'a str,
    pub workspaces: &'a dyn Workspaces,
    pub store: &'a Store,
    /// Starts the task of a retry, which runs after the round.
    pub spawn_retry: &'a (dyn Fn(Retry) + Sync),
}

/// The caller writes the returned router result lines under the state lock.
pub async fn execute(
    decisions: Vec<Decision>,
    events: &[RoutedEvent],
    ctx: &ExecuteContext<'_>,
) -> (Routing, Vec<LogLine>) {
    let mut routing = routing(&decisions);
    let started: Vec<u64> = decisions
        .iter()
        .filter_map(|decision| match &decision.action {
            Action::StartReview { iid, .. } | Action::StartBump { iid, .. } => Some(*iid),
            Action::RetryJob { .. } | Action::ReportOnly { .. } | Action::Dismiss | Action::AskModel => None,
        })
        .collect();
    let now = now_seconds();
    let mut lines = Vec::new();
    for decision in decisions {
        let row = decision.row;
        match decision.action {
            Action::StartReview {
                iid,
                title,
                branch,
                url,
            } => {
                lines.push(LogLine::Route(route_line(now, ctx.key, iid, RouteAction::Review)));
                let start = AgentStart {
                    title,
                    branch,
                    prompt: format!("/review-pr {url}"),
                };
                start_agent(ctx, &mut routing, row, &start, "Review agent started");
            }
            Action::StartBump {
                iid,
                title,
                branch,
                url,
            } => {
                lines.push(LogLine::Route(route_line(now, ctx.key, iid, RouteAction::Bump)));
                let start = AgentStart {
                    title,
                    branch,
                    prompt: format!("/bump {url}"),
                };
                if start_agent(ctx, &mut routing, row, &start, "Bump agent started") {
                    tokio::task::block_in_place(|| stale_agents(ctx, &mut routing, &start.branch));
                }
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
            Action::RetryJob {
                job,
                branch,
                pipeline,
                url,
            } => (ctx.spawn_retry)(Retry {
                job,
                branch,
                pipeline,
                url,
            }),
            Action::ReportOnly { .. } | Action::AskModel => {}
        }
    }
    (routing, lines)
}

fn dependency(branch: &str) -> Option<String> {
    let name = ["renovate/", "dependabot/"]
        .iter()
        .find_map(|prefix| branch.strip_prefix(prefix))?;
    let name = name.rsplit('/').next().unwrap_or(name);
    let is_version = |part: &str| {
        let digit_at = |index: usize| part.as_bytes().get(index).is_some_and(u8::is_ascii_digit);
        digit_at(0) || (part.starts_with('v') && digit_at(1)) || part.ends_with(".x")
    };
    match name.rsplit_once('-') {
        Some((dependency, version)) if is_version(version) => Some(dependency.to_string()),
        _ => Some(name.to_string()),
    }
}

/// The old workspace stays open, because it can have changes.
fn stale_agents(ctx: &ExecuteContext<'_>, routing: &mut Routing, branch: &str) {
    let Some(name) = dependency(branch) else {
        return;
    };
    let branches = match ctx.workspaces.agent_branches(ctx.repo) {
        Ok(branches) => branches,
        Err(error) => {
            ctx.store.log(ctx.key, ctx.key, &format!("stale check: {error}"));
            return;
        }
    };
    for old in branches
        .iter()
        .filter(|old| old.as_str() != branch && dependency(old).as_ref() == Some(&name))
    {
        routing.input.add.push(Add {
            section: AddSection::Agent,
            iid: None,
            what: Some(format!("The bump agent of {old} is stale")),
            result: None,
            url: None,
        });
    }
}

/// Only a new agent gives true. A failed start stays a pending item, with the error text as its cell.
fn start_agent(ctx: &ExecuteContext<'_>, routing: &mut Routing, row: u64, start: &AgentStart, started: &str) -> bool {
    let result = tokio::task::block_in_place(|| ctx.workspaces.start_agent(ctx.repo, start));
    let (cell, ok) = match result {
        Ok(()) => {
            routing.input.agent.push(row.into());
            (started.to_string(), true)
        }
        Err(StartError::Busy) => {
            routing.input.agent.push(row.into());
            ("An agent works on the branch".to_string(), false)
        }
        Err(StartError::Failed(text)) => (text, false),
    };
    routing.input.cells.insert(row.to_string(), cell.into());
    routing.handled.push(row);
    ok
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};

    use serde_json::json;

    use super::*;
    use crate::engine::event::Event;
    use crate::paths::StateDirs;
    use crate::workspaces::FakeWorkspaces;

    struct Setup {
        base: PathBuf,
        store: Store,
        workspaces: FakeWorkspaces,
        retried: Arc<Mutex<Vec<u64>>>,
        spawn_retry: Box<dyn Fn(Retry) + Sync>,
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
            let retried = Arc::new(Mutex::new(Vec::new()));
            let spawned = retried.clone();
            Setup {
                retried,
                spawn_retry: Box::new(move |retry: Retry| spawned.lock().unwrap().push(retry.job.id)),
                workspaces: FakeWorkspaces { dir: fake },
                store,
                base,
            }
        }

        fn context(&self) -> ExecuteContext<'_> {
            ExecuteContext {
                repo: &self.base,
                key: "app",
                workspaces: &self.workspaces,
                store: &self.store,
                spawn_retry: self.spawn_retry.as_ref(),
            }
        }

        fn calls(&self) -> String {
            std::fs::read_to_string(self.base.join("fake/calls")).unwrap_or_default()
        }
    }

    fn route_actions(lines: &[LogLine]) -> Vec<String> {
        lines
            .iter()
            .map(|line| serde_json::to_value(line).unwrap())
            .map(|line| format!("{} {}", line["iid"], line["action"].as_str().unwrap_or_default()))
            .collect()
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

        let (routing, lines) = execute(vec![start_review(3)], &[], &setup.context()).await;

        assert_eq!(routing.handled, [3]);
        assert_eq!(routing.input.cells["3"], "Review agent started");
        assert_eq!(routing.input.agent, [json!(3)]);
        assert_eq!(setup.calls(), "start_agent ABC-1/foo /review-pr https://g/mr/5\n");
        assert_eq!(route_actions(&lines), ["5 review"]);
        assert!(!setup.store.dirs.events().exists());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn busy_branch_is_an_agent_row() {
        let setup = Setup::new("busy", "busy");

        let (routing, _) = execute(vec![start_review(3)], &[], &setup.context()).await;

        assert_eq!(routing.handled, [3]);
        assert_eq!(routing.input.cells["3"], "An agent works on the branch");
        assert_eq!(routing.input.agent, [json!(3)]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn failed_start_gives_its_text_and_keeps_the_item() {
        let setup = Setup::new("failed", "work-start: not a git repo: /x");

        let (routing, _) = execute(vec![start_review(3)], &[], &setup.context()).await;

        assert_eq!(routing.handled, [3]);
        assert_eq!(routing.input.cells["3"], "work-start: not a git repo: /x");
        assert!(routing.input.agent.is_empty());
        assert!(routing.input.close.is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn retry_job_spawns_a_retry() {
        let setup = Setup::new("retry", "ok");
        let retry = Decision {
            row: 3,
            action: Action::RetryJob {
                job: crate::engine::event::FailedJob {
                    id: 11,
                    name: "build".to_string(),
                    failure_reason: Some("api_failure".to_string()),
                },
                branch: "main".to_string(),
                pipeline: 7,
                url: "u".to_string(),
            },
        };

        let (routing, _) = execute(vec![retry], &[], &setup.context()).await;

        assert_eq!(*setup.retried.lock().unwrap(), [11]);
        assert_eq!(routing.handled, [3]);
    }

    #[test]
    fn dependency_is_the_branch_name_with_no_bot_prefix_and_no_version() {
        assert_eq!(dependency("renovate/foo-1.x"), Some("foo".into()));
        assert_eq!(dependency("renovate/org-foo-bar-2.3.4"), Some("org-foo-bar".into()));
        assert_eq!(
            dependency("dependabot/npm_and_yarn/lodash-4.17.21"),
            Some("lodash".into())
        );
        assert_eq!(dependency("renovate/foo-v2"), Some("foo".into()));
        assert_eq!(dependency("feature/foo-1.x"), None);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn bump_start_marks_the_older_agent_of_the_dependency_stale() {
        let setup = Setup::new("stale", "ok");
        std::fs::write(setup.base.join("fake/branches"), "renovate/foo-1.x\nrenovate/bar-2.x\n").unwrap();
        let bump = Decision {
            row: 4,
            action: Action::StartBump {
                iid: 7,
                title: "Update foo to v2".to_string(),
                branch: "renovate/foo-2.x".to_string(),
                url: "https://g/mr/7".to_string(),
            },
        };

        let (routing, _) = execute(vec![bump], &[], &setup.context()).await;

        let added: Vec<serde_json::Value> = routing.input.add.iter().map(|add| json!(add)).collect();
        assert_eq!(
            added,
            [
                json!({"section": "agent", "iid": null, "what": "The bump agent of renovate/foo-1.x is stale",
                    "result": null, "url": null})
            ]
        );
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

        let (routing, lines) = execute(decisions, &[opened(1, 6), opened(2, 5)], &setup.context()).await;

        assert_eq!(routing.input.close, [json!(1), json!(2)]);
        assert_eq!(route_actions(&lines), ["6 none", "5 review"]);
    }
}
