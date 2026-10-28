//! The retry count is in the hub state, so that it stays after a daemon restart.

use std::sync::Arc;
use std::time::Duration;

use super::{Routing, is_runner_failure};
use crate::core::worktrees::Target;
use crate::daemon::{Daemon, NAP_STEP};
use crate::engine::event::{Event, EventKind, FailedJob};
use crate::engine::{EngineError, JobStatus, remote_url, split_remote};
use crate::nap::{NapEnd, nap};
use crate::platform::{full_wake, now_seconds, online};
use crate::report::{Add, AddSection, ReportInput};

pub struct Retry {
    pub job: FailedJob,
    pub branch: String,
    pub pipeline: u64,
    /// The URL of the pipeline.
    pub url: String,
}

/// A failure for another reason goes to the hub model as a `default-failed` event with only that job.
pub async fn retry(daemon: Arc<Daemon>, target: Target, retry: Retry) {
    let Retry {
        mut job,
        branch,
        pipeline,
        url,
    } = retry;
    let name = job.name.clone();
    let count_key = format!("{pipeline}:{name}");
    loop {
        let count = {
            let _memory = daemon.lock().await;
            daemon.store.retry_count(&target.slug, &count_key)
        };
        if count >= 2 {
            let text = format!("{branch}: job {name} failed 3 times (runner failure), stopped");
            return add_row(&daemon, &target, text).await;
        }
        let new = match daemon.engine.retry_job(target.repo.clone(), job.id).await {
            Ok(new) => new,
            Err(error) => return add_row(&daemon, &target, format!("{branch}: job {name}: {}", error.message())).await,
        };
        {
            let _memory = daemon.lock().await;
            daemon.store.set_retry_count(&target.slug, &count_key, count + 1);
        }
        let text = format!("{branch}: job {name} retried (runner failure), {} of 2", count + 1);
        add_row(&daemon, &target, text).await;
        let status = match wait(&daemon, &target, new.id).await {
            WaitEnd::Finished(status) => status,
            WaitEnd::Timeout => {
                return add_row(
                    &daemon,
                    &target,
                    format!("{branch}: job {name} did not finish in 1 hour"),
                )
                .await;
            }
            WaitEnd::Failed(text) => return add_row(&daemon, &target, format!("{branch}: job {name}: {text}")).await,
            WaitEnd::Stopped => return,
        };
        let failed = FailedJob {
            id: status.id,
            name: status.name,
            failure_reason: status.failure_reason,
        };
        match status.status.as_str() {
            "success" => return add_row(&daemon, &target, format!("{branch}: job {name} passed after retry")).await,
            "failed" if is_runner_failure(&failed) => job = failed,
            "failed" => return ask_model(&daemon, &target, failed, &branch, pipeline, &url).await,
            other => return add_row(&daemon, &target, format!("{branch}: job {name} {other} after retry")).await,
        }
    }
}

enum WaitEnd {
    Finished(JobStatus),
    Timeout,
    Failed(String),
    Stopped,
}

async fn wait(daemon: &Daemon, target: &Target, job_id: u64) -> WaitEnd {
    let remote = remote_url(&target.repo);
    let host = remote.as_deref().and_then(split_remote).map(|(host, _)| host);
    let mut waited = Duration::ZERO;
    loop {
        let end = nap(daemon.retry_interval, NAP_STEP, now_seconds, |step| async move {
            tokio::time::sleep(step).await;
            (false, full_wake().await)
        })
        .await;
        if daemon.stopping() {
            return WaitEnd::Stopped;
        }
        // Sleep time does not count.
        if end == NapEnd::Asleep {
            if !daemon.wait_network(&target.repo, host).await {
                return WaitEnd::Stopped;
            }
            continue;
        }
        match daemon.engine.job(target.repo.clone(), job_id).await {
            Ok(status) => match status.status.as_str() {
                "success" | "failed" | "canceled" | "skipped" => return WaitEnd::Finished(status),
                _ => {}
            },
            // A network outage does not count, but an error with the network up does, as for HTTP 502.
            Err(EngineError::Network(_)) if !online(host).await => {
                if !daemon.wait_network(&target.repo, host).await {
                    return WaitEnd::Stopped;
                }
                continue;
            }
            Err(EngineError::Network(_)) => {}
            Err(error) => return WaitEnd::Failed(error.message().trim_end().to_string()),
        }
        waited += daemon.retry_interval;
        if waited >= daemon.retry_timeout {
            return WaitEnd::Timeout;
        }
    }
}

async fn add_row(daemon: &Daemon, target: &Target, text: String) {
    let input = ReportInput {
        add: vec![Add {
            section: AddSection::Agent,
            iid: None,
            what: Some(text),
            result: None,
        }],
        ..ReportInput::default()
    };
    let memory = daemon.lock().await;
    daemon.store.add_rows(target, &input);
    drop(memory);
    daemon.changed.notify_waiters();
}

async fn ask_model(daemon: &Daemon, target: &Target, job: FailedJob, branch: &str, pipeline: u64, url: &str) {
    let event = Event {
        item: Some(format!("main-failed:{branch}")),
        jobs: Some(vec![job.name.clone()]),
        failed: Some(vec![job]),
        ..Event::new(
            EventKind::DefaultFailed,
            None,
            None,
            url,
            "",
            &format!("pipeline {pipeline} failed"),
            branch,
        )
    };
    let memory = daemon.lock().await;
    let routed = daemon.store.assign(target, vec![event], now_seconds());
    daemon.store.deliver(target, &routed, &Routing::default());
    drop(memory);
    daemon.changed.notify_waiters();
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::time::Duration;

    use super::*;
    use crate::core::subs::{Agent, Mode};
    use crate::daemon::store::Store;
    use crate::engine::fake::FakeEngine;
    use crate::paths::StateDirs;
    use crate::workspaces::FakeWorkspaces;

    struct Setup {
        base: PathBuf,
        daemon: Arc<Daemon>,
    }

    impl Setup {
        fn new(name: &str, timeout: Duration) -> Setup {
            let base = std::env::temp_dir().join(format!("watchd-retry-{}-{name}", std::process::id()));
            let _ = std::fs::remove_dir_all(&base);
            let store = Store::new(StateDirs {
                watchd: base.join("watchd"),
                engine: base.join("watch-gitlab"),
            });
            store.ensure_dirs().unwrap();
            let fake = base.join("fake");
            std::fs::create_dir_all(&fake).unwrap();
            let mut daemon = Daemon::new(
                store,
                Box::new(FakeEngine {
                    dir: fake.clone(),
                    engine_dir: base.join("watch-gitlab"),
                }),
                Box::new(FakeWorkspaces { dir: fake }),
            );
            daemon.retry_interval = Duration::ZERO;
            daemon.retry_timeout = timeout;
            Setup {
                base,
                daemon: Arc::new(daemon),
            }
        }

        /// `lines` are `id status failure_reason`, one for each status read.
        fn job(&self, file: &str, lines: &[&str]) {
            let text: Vec<String> = lines
                .iter()
                .map(|line| {
                    let fields: Vec<&str> = line.split(' ').collect();
                    let reason = fields.get(2).map_or(serde_json::Value::Null, |reason| (*reason).into());
                    serde_json::json!({"id": fields[0].parse::<u64>().unwrap(), "name": "build",
                                       "status": fields[1], "failure_reason": reason})
                    .to_string()
                })
                .collect();
            std::fs::write(self.base.join("fake").join(file), text.join("\n")).unwrap();
        }

        fn target(&self) -> Target {
            Target {
                key: "app".to_string(),
                slug: "app".to_string(),
                mode: Mode::Hub,
                repo: self.base.clone(),
                mrs: Vec::new(),
            }
        }

        async fn run(&self) {
            let job = FailedJob {
                id: 11,
                name: "build".to_string(),
                failure_reason: Some("runner_system_failure".to_string()),
            };
            let start = Retry {
                job,
                branch: "main".to_string(),
                pipeline: 7,
                url: "https://g/-/pipelines/7".to_string(),
            };
            retry(self.daemon.clone(), self.target(), start).await;
        }

        fn rows(&self) -> Vec<String> {
            let log = std::fs::read_to_string(self.daemon.store.dirs.log()).unwrap_or_default();
            log.lines()
                .filter_map(|line| line.split_once(" row: ").map(|(_, row)| row.to_string()))
                .collect()
        }
    }

    #[tokio::test]
    async fn retried_job_that_passes() {
        let setup = Setup::new("passes", Duration::from_secs(3600));
        setup.job("retry-11.json", &["21 pending"]);
        setup.job("job-21.json", &["21 running", "21 success"]);

        setup.run().await;

        assert_eq!(
            setup.rows(),
            [
                "main: job build retried (runner failure), 1 of 2",
                "main: job build passed after retry"
            ]
        );
        assert_eq!(setup.daemon.store.retry_count("app", "7:build"), 1);
    }

    #[tokio::test]
    async fn second_runner_failure_retries_again() {
        let setup = Setup::new("again", Duration::from_secs(3600));
        setup.job("retry-11.json", &["21 pending"]);
        setup.job("job-21.json", &["21 failed runner_system_failure"]);
        setup.job("retry-21.json", &["22 pending"]);
        setup.job("job-22.json", &["22 success"]);

        setup.run().await;

        assert_eq!(
            setup.rows(),
            [
                "main: job build retried (runner failure), 1 of 2",
                "main: job build retried (runner failure), 2 of 2",
                "main: job build passed after retry"
            ]
        );
    }

    #[tokio::test]
    async fn third_runner_failure_stops() {
        let setup = Setup::new("stops", Duration::from_secs(3600));
        setup.job("retry-11.json", &["21 pending"]);
        setup.job("job-21.json", &["21 failed scheduler_failure"]);
        setup.job("retry-21.json", &["22 pending"]);
        setup.job("job-22.json", &["22 failed api_failure"]);

        setup.run().await;

        assert_eq!(
            setup.rows().last().map(String::as_str),
            Some("main: job build failed 3 times (runner failure), stopped")
        );
        assert_eq!(
            std::fs::read_to_string(setup.base.join("fake/args")).unwrap(),
            "retry 11\nretry 21\n"
        );
    }

    #[tokio::test]
    async fn other_failure_goes_to_the_model_with_only_that_job() {
        let setup = Setup::new("other", Duration::from_secs(3600));
        setup.daemon.store.write_sub(&Agent {
            key: "app".to_string(),
            slug: "app".to_string(),
            repo: setup.base.clone(),
            mode: Mode::Hub,
            mrs: Vec::new(),
            interval: 120,
            session_pid: std::process::id(),
            client_pid: 0,
            client_at: 0,
            replaced_sessions: Vec::new(),
            ended_mrs: Vec::new(),
        });
        setup.job("retry-11.json", &["21 pending"]);
        setup.job("job-21.json", &["21 failed script_failure"]);

        setup.run().await;

        let inbox = setup.daemon.store.take_inbox("app");
        assert_eq!(inbox.len(), 1);
        let event = &inbox[0].event;
        assert_eq!(
            (event.kind, event.jobs.clone(), event.url.as_str()),
            (
                crate::engine::event::EventKind::DefaultFailed,
                Some(vec!["build".to_string()]),
                "https://g/-/pipelines/7"
            )
        );
        assert_eq!(
            event.failed,
            Some(vec![FailedJob {
                id: 21,
                name: "build".to_string(),
                failure_reason: Some("script_failure".to_string())
            }])
        );
    }

    #[tokio::test]
    async fn canceled_job_after_retry() {
        let setup = Setup::new("canceled", Duration::from_secs(3600));
        setup.job("retry-11.json", &["21 pending"]);
        setup.job("job-21.json", &["21 canceled"]);

        setup.run().await;

        assert_eq!(
            setup.rows().last().map(String::as_str),
            Some("main: job build canceled after retry")
        );
    }

    #[tokio::test]
    async fn job_that_does_not_finish_times_out() {
        let setup = Setup::new("timeout", Duration::ZERO);
        setup.job("retry-11.json", &["21 pending"]);
        setup.job("job-21.json", &["21 running"]);

        setup.run().await;

        assert_eq!(
            setup.rows().last().map(String::as_str),
            Some("main: job build did not finish in 1 hour")
        );
    }

    #[tokio::test]
    async fn retry_count_survives_a_restart() {
        let setup = Setup::new("restart", Duration::from_secs(3600));
        setup.daemon.store.set_retry_count("app", "7:build", 1);
        setup.job("retry-11.json", &["21 pending"]);
        setup.job("job-21.json", &["21 success"]);

        setup.run().await;

        assert_eq!(
            setup.rows().first().map(String::as_str),
            Some("main: job build retried (runner failure), 2 of 2")
        );
    }
}
